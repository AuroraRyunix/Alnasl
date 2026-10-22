defmodule Alnasl.Contracts.BridgeTest do
  @moduledoc """
  Arkab's `bridge-protocol-v1` (vendored), from Alnasl's side: Alnasl is the
  server a bridge joins and dials.

  Every frame the contract has an example of in the bridge-to-server
  direction is put through the real socket (`AlnaslWeb.BridgeSocket`), and
  every frame and join answer Alnasl gives back is checked against the
  schemas. The stand-in second server of the other tests
  (`Alnasl.OtherServer`) is held to the same schemas.
  """

  use AlnaslWeb.SiteCase, async: false

  @moduletag :capture_log

  alias Alnasl.{Bridges, Contract, Halls}
  alias Alnasl.Bridges.Bridge
  alias AlnaslWeb.BridgeSocket

  @hello Contract.example(:bridge, "hello")

  defp post_join(code, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/join/#{code}", Jason.encode!(body))
  end

  describe "joining" do
    test "the contract's join request is taken, and the answer fits join-response" do
      {:ok, join} = Bridges.create_join()
      request = Contract.example(:bridge, "join-request")

      answer = post_join(join.code, request) |> json_response(200)
      Contract.assert_valid!(:bridge, "join-response", answer)
      assert {:ok, %Bridge{}} = Bridges.authenticate(request["bridge"], answer["key"])
    end

    test "a refusal is one of the statuses the contract gives the bridge" do
      # The ones the bridge tells apart (join-request.schema.json): 404/410
      # the code, 409 the version, 403 elsewhere.
      request = Contract.example(:bridge, "join-request")

      {:ok, join} = Bridges.create_join()
      assert post_join(join.code, request).status == 200
      assert post_join(join.code, request).status == 410
      assert post_join("NOT-ACODE", request).status in [404, 410]

      {:ok, other} = Bridges.create_join()
      assert post_join(other.code, %{request | "v" => 2}).status == 409

      # Still in another hall, and joining this one.
      hall = Repo.insert!(%Alnasl.Halls.Hall{name: "Elsewhere"})
      {:ok, there} = Bridges.create_join(DateTime.utc_now(:second), hall.id)

      assert %{"error" => "elsewhere"} = post_join(there.code, request) |> json_response(403)
    end
  end

  # --- the link ----------------------------------------------------------------

  # The bridge of hello.json, joined here with hello.json's key.
  defp the_bridge(changes \\ %{}) do
    Repo.insert!(
      struct(
        %Bridge{
          uid: @hello["bridge"],
          name: @hello["name"],
          software: @hello["software"],
          key_hash: :crypto.hash(:sha256, @hello["key"]) |> Base.encode16(case: :lower),
          hall_id: Halls.own_id()
        },
        changes
      )
    )
  end

  defp connect do
    {:ok, state} = BridgeSocket.connect(%{})
    {:ok, state} = BridgeSocket.init(state)
    state
  end

  defp say(state, frame),
    do: BridgeSocket.handle_in({Jason.encode!(frame), [opcode: :text]}, state)

  defp said({:reply, :ok, {:text, text}, state}), do: {Jason.decode!(text), state}

  defp schema_of(%{"type" => type}), do: type

  defp hello(state \\ connect()) do
    {welcome, state} = state |> say(@hello) |> said()
    {welcome, state}
  end

  describe "the link" do
    test "hello is welcomed with a welcome, and the resend every connect asks for is a command" do
      bridge = the_bridge(%{seen_seq: 1039})
      {welcome, state} = hello()

      Contract.assert_valid!(:bridge, "welcome", welcome)
      assert welcome["seen"] == bridge.seen_seq

      assert_received {:command, command}
      assert {:push, {:text, text}, _state} = BridgeSocket.handle_info({:command, command}, state)

      assert Contract.assert_valid!(:bridge, "command", text) ==
               Contract.example(:bridge, "command")
    end

    test "a hello that is not taken is refused with a reason the contract knows" do
      the_bridge()

      for {hello, reason} <- [
            {%{@hello | "key" => "not-the-key"}, "key"},
            {%{@hello | "v" => 2}, "version"}
          ] do
        {refused, _state} = connect() |> say(hello) |> said()
        assert Contract.assert_valid!(:bridge, "refused", refused)["reason"] == reason
      end

      Repo.update_all(Bridge, set: [revoked_at: DateTime.utc_now(:second)])
      {refused, _state} = connect() |> say(@hello) |> said()

      assert Contract.assert_valid!(:bridge, "refused", refused) ==
               Contract.example(:bridge, "refused.revoked")
    end

    test "every board, event, reply and leave the contract shows is taken; events are acknowledged" do
      the_bridge()
      {_welcome, state} = hello()

      {:ok, state} = say(state, Contract.example(:bridge, "boards.empty"))
      {:ok, state} = say(state, Contract.example(:bridge, "boards"))
      assert %{boards: [_, _], recording?: true} = Bridges.live(Repo.one!(Bridge).id)

      state =
        for {name, events} <- Contract.examples(:bridge, "events"), reduce: state do
          state ->
            {ack, state} = state |> say(events) |> said()
            Contract.assert_valid!(:bridge, "ack", ack)
            highest = events["events"] |> Enum.map(& &1["s"]) |> Enum.max()
            # Everything is acknowledged, also what was already held (the
            # played example's numbers are below the first's).
            assert ack["seq"] == max(highest, state.bridge.seen_seq), name
            state
        end

      for {_name, reply} <- Contract.examples(:bridge, "reply") do
        Bridges.subscribe()
        {:ok, _state} = say(state, reply)
        ok? = reply["ok"]
        id = reply["id"]
        assert_received {:bridges, {:reply, _bridge, ^id, ^ok?, _error}}
      end

      assert {:stop, :normal, _state} = say(state, Contract.example(:bridge, "leave"))
    end

    test "every command Alnasl gives fits the contract" do
      bridge = the_bridge()
      {_welcome, state} = hello()
      assert_received {:command, _hello_resend}

      # As the Bridges tab sends them: the button's cmd, its port or board.
      for {cmd, fields} <- [
            {"rescan", %{"port" => "COM3"}},
            {"add_port", %{"port" => "/dev/ttyUSB7"}},
            {"forget_port", %{"port" => "COM4"}},
            {"resend", %{}},
            {"forget_board", %{"board" => "COM4#12799"}}
          ] do
        assert {:ok, id} = Bridges.command(bridge.id, cmd, fields)
        assert_received {:command, command}
        {:push, {:text, text}, _state} = BridgeSocket.handle_info({:command, command}, state)
        frame = Contract.assert_valid!(:bridge, "command", text)
        assert frame["id"] == id and frame["cmd"] == cmd
      end

      # Removing the bridge here says leave.
      assert {:push, {:text, text}, _state} = BridgeSocket.handle_info(:leave, state)
      assert Contract.assert_valid!(:bridge, "leave", text) == Contract.example(:bridge, "leave")
    end

    test "every frame of the link names a schema" do
      for {schema, name, frame} <- Contract.examples(:bridge),
          schema not in ~w(join-request join-response dgt-serial-opening) do
        assert schema_of(frame) == schema, name
      end
    end
  end

  describe "the stand-in second server" do
    test "answers a join and a hello as the contract says" do
      server = Alnasl.OtherServer.start()

      {:ok, answer} =
        Req.post("http://127.0.0.1:#{server.port}/join/OTHER",
          json: Contract.example(:bridge, "join-request"),
          retry: false
        )

      Contract.assert_valid!(:bridge, "join-response", answer.body)

      {:ok, agent} = Agent.start_link(fn -> %{seqs: [], seen: 0} end)

      {:push, {:text, welcome}, agent} =
        Alnasl.OtherServer.Socket.handle_in({Jason.encode!(@hello), [opcode: :text]}, agent)

      Contract.assert_valid!(:bridge, "welcome", welcome)

      {:push, {:text, ack}, _agent} =
        Alnasl.OtherServer.Socket.handle_in(
          {Jason.encode!(Contract.example(:bridge, "events")), [opcode: :text]},
          agent
        )

      assert Contract.assert_valid!(:bridge, "ack", ack)["seq"] == 1055
    end
  end
end
