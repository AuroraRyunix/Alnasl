defmodule Alnasl.OpenPairingsTest do
  @moduledoc """
  The conversation with the pairing program: a code is taken, the listing
  is polled with its ETag, a tournament whose version changed is fetched,
  and what stops working is said and survived.

  The pairing program here is `Alnasl.FakeOpenPairings`, written from the
  contract. No real OpenPairings is spoken to.
  """

  use Alnasl.DataCase, async: false

  import Alnasl.LinkHelpers

  alias Alnasl.{FakeOpenPairings, OpenPairings, Repo, Tournaments}
  alias Alnasl.Tournaments.Link

  setup do
    pairing_program()
  end

  describe "a connect code" do
    test "brings its tournament: pairings, rate of play, and the results page with its key" do
      FakeOpenPairings.add_tournament(17, name: "Summer Open", boards: 3)
      code = FakeOpenPairings.code(17)

      assert {:ok, %Link{} = link, [tournament]} = OpenPairings.add_code(code)
      assert link.state == "ok" and link.kind == "tournament"
      assert link.server_version == "0.0.0-fake"
      assert link.root == FakeOpenPairings.root()

      assert tournament.kind == "linked" and tournament.remote_id == 17
      assert tournament.name == "Summer Open"
      assert tournament.remote_round == 1 and tournament.round == 1

      # Nothing was typed on the box for the results site.
      assert tournament.server_url == "http://results.test"
      assert tournament.slug == "slug-17"
      assert tournament.relay_key == FakeOpenPairings.relay_key(17)
      assert Tournaments.openresults_configured?(tournament)

      assert [
               %{board: 1, white: "IM Summer Open Player 1", black: "Summer Open Player 2"} = one
               | _
             ] =
               Tournaments.boards(tournament.id, 1)

      assert one.white_rating == 2001 and one.white_id == 17_001 and one.game == "g17r1b1s0"
      assert length(Tournaments.boards(tournament.id, 1)) == 3
      assert Tournaments.info(tournament.id).time_control == "90min+30sec/move"

      # The secret is kept, because it must be sent - and only a hint is shown.
      assert Repo.get!(Link, link.id).secret == FakeOpenPairings.secret(code)
      hint = Tournaments.secret_hint(link)
      assert hint =~ "..." and String.length(hint) < 15
      refute inspect(link) =~ FakeOpenPairings.secret(code)
    end

    test "every request carries the secret as a bearer token and says which box asks" do
      Alnasl.Settings.put("box_name", "Hall A")
      FakeOpenPairings.add_tournament(17)
      {:ok, link, _} = OpenPairings.add_code(FakeOpenPairings.code(17))

      assert :ok = OpenPairings.tell(link)
      assert [{{:tournament, 17}, told}] = FakeOpenPairings.boxes()
      assert told["name"] == "Hall A" and told["boards"] == %{"17" => 0}
      assert is_binary(told["version"])
    end

    test "that is no code, or one the box has, is not taken" do
      assert OpenPairings.add_code("") == {:error, :empty}
      assert OpenPairings.add_code("https://pairings.test/api/boards/v1") == {:error, :no_secret}

      FakeOpenPairings.add_tournament(17)
      code = FakeOpenPairings.code(17)
      assert {:ok, _link, _} = OpenPairings.add_code(code)
      assert OpenPairings.add_code(" " <> code <> "\n") == {:error, :already}
      assert Repo.aggregate(Link, :count) == 1
    end

    test "that the pairing program refuses is not kept" do
      wrong = FakeOpenPairings.root() <> "#" <> "oplt" <> "_" <> String.duplicate("z", 30)
      assert OpenPairings.add_code(wrong) == {:error, :unauthorized}
      assert Repo.aggregate(Link, :count) == 0
    end

    test "is kept when nobody answers, and works when somebody does" do
      FakeOpenPairings.add_tournament(17)
      FakeOpenPairings.mode(:down)

      assert {:pending, link, {:unreachable, :econnrefused}} =
               OpenPairings.add_code(FakeOpenPairings.code(17))

      assert link.state == "unreachable"
      assert Tournaments.of_link(link) == []

      FakeOpenPairings.mode(:ok)
      poll()
      assert [%{remote_id: 17, document: document}] = Tournaments.of_link(link)
      assert is_binary(document)
    end

    test "for a program that speaks another version of the link is refused, in so many words" do
      FakeOpenPairings.add_tournament(17)
      FakeOpenPairings.mode({:api, 2})
      assert OpenPairings.add_code(FakeOpenPairings.code(17)) == {:error, {:unsupported, 2}}
      assert Repo.aggregate(Link, :count) == 0
    end

    test "at an address where something else answers" do
      FakeOpenPairings.add_tournament(17)
      FakeOpenPairings.mode(:not_the_api)
      assert {:pending, _link, :not_the_api} = OpenPairings.add_code(FakeOpenPairings.code(17))
    end
  end

  describe "polling" do
    test "sends the ETag back, and an unchanged listing costs one request and no document" do
      tournament = linked(17)
      FakeOpenPairings.reset_requests()

      poll()
      poll()

      assert [
               {"GET", "/api/boards/v1/link", 304, nil},
               {"GET", "/api/boards/v1/link", 304, nil}
             ] = FakeOpenPairings.requests()

      assert again(tournament).version == tournament.version
    end

    test "a tournament whose version changed is fetched; the others are left alone" do
      FakeOpenPairings.add_tournament(17, group: "Festival", label: "Open")
      FakeOpenPairings.add_tournament(18, group: "Festival", label: "U12")
      {:ok, _link, [_, _]} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))
      open = by_remote(17)
      FakeOpenPairings.reset_requests()

      FakeOpenPairings.pair(18, 2, 2)
      poll()

      assert [
               {"GET", "/api/boards/v1/link", 200, nil},
               {"GET", "/api/boards/v1/tournaments/18", 200, nil}
             ] = FakeOpenPairings.requests()

      assert Tournaments.rounds(by_remote(18).id) == [1, 2]
      assert again(open).version == open.version
    end

    test "a tournament added to the group later appears without a new code" do
      FakeOpenPairings.add_tournament(17, group: "Festival", label: "Open")
      {:ok, link, [only]} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))
      assert only.label == "Open"
      assert Repo.get!(Link, link.id).group_name == "Festival"

      FakeOpenPairings.add_tournament(18, group: "Festival", label: "U12", boards: 4)
      poll()

      assert [%{remote_id: 17}, %{remote_id: 18, label: "U12"} = added] =
               Tournaments.of_link(link)

      assert length(Tournaments.boards(added.id, 1)) == 4
      assert Enum.map(Tournaments.active(), & &1.remote_id) == [17, 18]
    end

    test "a tournament that leaves the listing is marked gone, kept, and comes back if it does" do
      FakeOpenPairings.add_tournament(17, group: "Festival")
      FakeOpenPairings.add_tournament(18, group: "Festival")
      {:ok, link, _} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))

      FakeOpenPairings.update(18, &%{&1 | group: nil})
      poll()
      assert %{gone: true, document: document} = by_remote(18)
      assert is_binary(document)
      refute by_remote(17).gone
      assert Enum.map(Tournaments.active(), & &1.remote_id) == [17]

      FakeOpenPairings.update(18, &%{&1 | group: "Festival"})
      poll()
      refute by_remote(18).gone
      assert length(Tournaments.of_link(link)) == 2
    end

    test "offline, the last document is kept and the link says so; back, it carries on" do
      tournament = linked(17)
      FakeOpenPairings.mode(:down)
      poll()

      assert %{state: "unreachable"} = Repo.one!(Link)
      assert length(Tournaments.boards(tournament.id, 1)) == 2

      # What happened meanwhile is learned when the line is back.
      FakeOpenPairings.mode(:ok)
      FakeOpenPairings.pair(17, 2, 2)
      FakeOpenPairings.mode(:down)
      poll()
      assert Tournaments.rounds(tournament.id) == [1]

      FakeOpenPairings.mode(:ok)
      poll()
      assert %{state: "ok", last_ok_at: %DateTime{}} = Repo.one!(Link)
      assert Tournaments.rounds(tournament.id) == [1, 2]
    end

    test "a server error or a rate limit is not the end of the link" do
      linked(17)
      FakeOpenPairings.mode({:status, 500})
      assert {:error, {:http, 500}} = OpenPairings.poll(Repo.one!(Link))
      assert Repo.one!(Link).state == "unreachable"

      FakeOpenPairings.mode(:rate_limited)
      assert {:error, {:rate_limited, 60_000}} = OpenPairings.poll(Repo.one!(Link))

      FakeOpenPairings.mode(:ok)
      assert {:ok, %{state: "ok"}} = OpenPairings.poll(Repo.one!(Link))
    end

    test "a withdrawn code is not asked again and again; a new try is the arbiter's" do
      FakeOpenPairings.add_tournament(17)
      code = FakeOpenPairings.code(17)
      {:ok, link, _} = OpenPairings.add_code(code)

      FakeOpenPairings.withdraw(code)
      poll()
      assert %{state: "unauthorized"} = link = Repo.get!(Link, link.id)
      refute OpenPairings.polled?(link)

      FakeOpenPairings.reset_requests()
      poll()
      poll()
      assert FakeOpenPairings.requests() == []

      # The tournament and its pairings are still on the box.
      assert length(Tournaments.boards(by_remote(17).id, 1)) == 2
      assert {:error, :unauthorized} = OpenPairings.retry(link)
    end
  end

  describe "the results page" do
    test "of a tournament that is not published is nothing, and arrives when it is" do
      tournament = linked(17, openresults: nil)
      refute Tournaments.openresults_configured?(tournament)
      assert tournament.server_url == ""

      FakeOpenPairings.update(17, fn t ->
        %{
          t
          | openresults: %{
              "server_url" => "https://results.example.org/",
              "slug" => "k3v9x2",
              "relay_key" => nil
            }
        }
      end)

      poll()
      # Published, but the arbiter saved no key: an address, and nothing to send with.
      assert %{server_url: "https://results.example.org", slug: "k3v9x2", relay_key: ""} =
               tournament = again(tournament)

      refute Tournaments.openresults_configured?(tournament)

      FakeOpenPairings.update(
        17,
        &put_in(&1.openresults["relay_key"], FakeOpenPairings.relay_key(17))
      )

      poll()
      assert Tournaments.openresults_configured?(again(tournament))

      # Publishing switched off again: the box stops sending there.
      FakeOpenPairings.update(17, &%{&1 | openresults: nil})
      poll()
      refute Tournaments.openresults_configured?(again(tournament))
    end
  end

  describe "test connection" do
    test "says what the code reaches and what each tournament came with" do
      FakeOpenPairings.add_tournament(17, group: "Festival", label: "Open", boards: 3)
      FakeOpenPairings.add_tournament(18, group: "Festival", label: "U12", openresults: nil)
      {:ok, link, _} = OpenPairings.add_code(FakeOpenPairings.group_code("Festival"))

      assert [server: :ok, code: :ok, tournaments: {:ok, [open, u12]}] = OpenPairings.test(link)
      assert %{name: "Open", current_round: 1, boards: 3, openresults: :ok} = open
      assert %{name: "U12", openresults: :not_published} = u12
    end

    test "tells a withdrawn code from a server that is not there" do
      FakeOpenPairings.add_tournament(17)
      code = FakeOpenPairings.code(17)
      {:ok, link, _} = OpenPairings.add_code(code)

      FakeOpenPairings.mode(:down)

      assert [
               server: {:error, {:unreachable, :econnrefused}},
               code: :skipped,
               tournaments: :skipped
             ] =
               OpenPairings.test(link)

      FakeOpenPairings.mode(:ok)
      FakeOpenPairings.withdraw(code)

      assert [server: :ok, code: {:error, :unauthorized}, tournaments: :skipped] =
               OpenPairings.test(link)

      # Testing changed nothing.
      assert Repo.get!(Link, link.id).state == "ok"
    end
  end

  describe "the poller" do
    defp wait_until(fun, left \\ 300) do
      cond do
        fun.() ->
          :ok

        left == 0 ->
          flunk("timed out waiting")

        true ->
          receive do
          after
            20 -> wait_until(fun, left - 1)
          end
      end
    end

    test "asks by itself, learns what changed, and tells the pairing program which box this is" do
      tournament = linked(17)
      FakeOpenPairings.pair(17, 2, 2)

      start_supervised!(Alnasl.OpenPairings.Poller)
      wait_until(fn -> Tournaments.rounds(tournament.id) == [1, 2] end)
      wait_until(fn -> FakeOpenPairings.boxes() != [] end)
      assert [{{:tournament, 17}, %{"boards" => %{"17" => 0}}} | _] = FakeOpenPairings.boxes()

      # A code that is refused is left alone from then on.
      FakeOpenPairings.withdraw(FakeOpenPairings.root() <> "#" <> Repo.one!(Link).secret)
      Alnasl.OpenPairings.Poller.poll_now()
      wait_until(fn -> Repo.one!(Link).state == "unauthorized" end)
      FakeOpenPairings.reset_requests()
      Alnasl.OpenPairings.Poller.poll_now()
      _ = :sys.get_state(Alnasl.OpenPairings.Poller)
      assert FakeOpenPairings.requests() == []
    end
  end

  describe "taking a code off the box" do
    test "takes its tournaments with it and leaves the box's own alone" do
      own = Tournaments.default()
      tournament = linked(17)
      link = Repo.one!(Link)

      assert :ok = OpenPairings.remove_link(link)
      assert Repo.aggregate(Link, :count) == 0
      assert Tournaments.get(tournament.id) == nil
      assert Tournaments.default().id == own.id
      assert Tournaments.remove(own) == {:error, :own}
    end
  end
end
