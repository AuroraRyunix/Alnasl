defmodule Alnasl.Bridges do
  @moduledoc """
  The Arkab bridges that bring boards here from elsewhere: a hall with a
  Raspberry Pi and no Alnasl of its own, or a box that sends its hall to a
  server as well. The bridge dials out; this side lets it in, takes its
  events, acknowledges them, and sends commands back
  (`AlnaslWeb.BridgeSocket`; the link is Arkab's `docs/protocol.md`).

  ## Joining

  `create_join/2` makes a code for a hall, good for fifteen minutes and one
  bridge; the hall's page (and Setup, for the hall it is about) shows
  `https://<this box>/join/<code>` as text and as a QR code. The bridge
  posts who it is to that link and is given its own long key (`redeem/2`).
  Only the key's hash is kept here. The bridge is in the code's hall, and
  so are its boards; an admin can `move/2` it to another.

  The link and the socket are outside the sign-in and the PIN: a bridge has
  no account. The code and the key are its credentials.

  ## Boards

  The bridge names each board by its port, and its address on a loop
  (`Arkab.Protocol.board_id/2`). That name becomes a row's `port`:
  `"bridge-<id>:<name>"`, driver `"remote"` (`Alnasl.Driver.Remote`). What
  the row is from then on is decided here as for any board: by its serial
  (`Alnasl.Tables.recognise/4`) - a board carried from the box's own port to
  a bridge keeps its table number and its game.

  ## Removing

  Either side. Removed here (`remove/1`), the row is kept as revoked and a
  connected bridge is told to forget this server; a bridge that dials in
  later is told the same. Removed on the bridge, it says `leave` and the
  same happens here (`forget/1`). Its board rows go with it.
  """

  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Boards, Halls, Log, Repo, Settings}
  alias Alnasl.Boards.Board
  alias Alnasl.Bridges.{Bridge, Join}

  @topic "bridges"
  @join_minutes 15
  # No 0/O, no 1/I/L: read off a screen across a hall, if it comes to that.
  @alphabet ~c"23456789ABCDEFGHJKMNPQRSTUVWXYZ"

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc false
  def notify(message \\ :changed),
    do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:bridges, message})

  # --- joining -----------------------------------------------------------------

  @doc """
  A fresh join code: `{:ok, %Join{}}`, for a bridge that goes into hall
  `hall_id` (the box's own hall when nobody says). Old codes are tidied
  away on the way.
  """
  def create_join(now \\ DateTime.utc_now(:second), hall_id \\ nil) do
    Repo.delete_all(from j in Join, where: j.expires_at < ^now)

    %Join{
      code: code(),
      expires_at: DateTime.add(now, @join_minutes * 60),
      hall_id: hall_id || Halls.own_id()
    }
    |> Repo.insert()
  end

  defp code do
    chars = for _ <- 1..7, do: Enum.random(@alphabet)
    {first, last} = Enum.split(chars, 3)
    List.to_string(first) <> "-" <> List.to_string(last)
  end

  @doc """
  A bridge redeems a code with who it is (`%{"v", "bridge", "name",
  "software"}`): `{:ok, %{key, bridge}}`, or `{:error, :used_or_expired |
  :version | :bad_request}`. A bridge that was here before (the same
  `uid`) is the same row with a new key, removed or not.
  """
  def redeem(code, identity, now \\ DateTime.utc_now(:second))

  def redeem(code, %{"v" => v, "bridge" => uid, "name" => name} = identity, now)
      when is_binary(code) and is_binary(uid) and uid != "" and is_binary(name) do
    if Arkab.Protocol.accepts?(v) do
      Repo.transaction(fn ->
        with %Join{} = join <- Repo.get_by(Join, code: String.upcase(code)),
             nil <- join.used_at,
             :gt <- DateTime.compare(join.expires_at, now) do
          key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

          fields = %{
            name: String.slice(name, 0, 80),
            software: identity["software"] |> to_string() |> String.slice(0, 80),
            key_hash: hash(key),
            revoked_at: nil,
            hall_id: join.hall_id || Halls.own_id()
          }

          bridge =
            case Repo.get_by(Bridge, uid: uid) do
              nil ->
                Repo.insert!(struct(Bridge, Map.put(fields, :uid, uid)))

              old ->
                bridge = old |> Ecto.Changeset.change(fields) |> Repo.update!()
                # Joined again from another hall: its boards (if any are
                # left from before) go with it.
                if old.hall_id != bridge.hall_id, do: move_rows(bridge)
                bridge
            end

          join |> Ecto.Changeset.change(used_at: now, bridge_id: bridge.id) |> Repo.update!()
          %{key: key, bridge: bridge}
        else
          _used_or_expired -> Repo.rollback(:used_or_expired)
        end
      end)
      |> tap(fn
        {:ok, %{bridge: bridge}} ->
          Log.add(:info, "bridge.joined", %{name: bridge.name}, %{})
          notify()

        _error ->
          :ok
      end)
    else
      {:error, :version}
    end
  end

  def redeem(_code, _identity, _now), do: {:error, :bad_request}

  defp hash(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  @doc """
  The bridge that says it is `uid` with `key`: `{:ok, bridge}`, or `{:error,
  :key}` (not a key this box gave), or `{:error, :revoked}` (removed here).
  """
  def authenticate(uid, key) when is_binary(uid) and is_binary(key) do
    case Repo.get_by(Bridge, uid: uid) do
      nil ->
        {:error, :key}

      %Bridge{} = bridge ->
        cond do
          not Plug.Crypto.secure_compare(hash(key), bridge.key_hash) -> {:error, :key}
          bridge.revoked_at != nil -> {:error, :revoked}
          true -> {:ok, bridge}
        end
    end
  end

  def authenticate(_uid, _key), do: {:error, :key}

  # --- the list ----------------------------------------------------------------

  @doc "The bridges let in and not removed, oldest first."
  def list do
    Repo.all(from b in Bridge, where: is_nil(b.revoked_at), order_by: b.id)
  end

  def get(id), do: Repo.get(Bridge, id)

  @doc """
  What a connected bridge last said about itself: `%{boards, ports,
  recording?, connected_at}`, or `nil` when it is not connected.
  """
  def live(bridge_id) do
    case Registry.lookup(Alnasl.BridgeRegistry, bridge_id) do
      [{_pid, value}] -> value
      [] -> nil
    end
  end

  def link(bridge_id) do
    case Registry.lookup(Alnasl.BridgeRegistry, bridge_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "The highest event number taken from `bridge`, kept."
  def seen(%Bridge{id: id}, seq) when is_integer(seq) do
    Repo.update_all(from(b in Bridge, where: b.id == ^id and b.seen_seq < ^seq),
      set: [seen_seq: seq]
    )

    :ok
  end

  def connected(%Bridge{} = bridge) do
    bridge
    |> Ecto.Changeset.change(last_connected_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  # --- commands ----------------------------------------------------------------

  @doc """
  Sends `cmd` to a connected bridge (`Arkab.Protocol.commands/0`):
  `{:ok, command_id}`, or `{:error, :offline}`. The answer comes as
  `{:bridges, {:reply, bridge_id, command_id, ok?, error}}`.
  """
  def command(bridge_id, cmd, fields \\ %{}) when is_binary(cmd) do
    if cmd in Arkab.Protocol.commands() do
      case link(bridge_id) do
        nil ->
          {:error, :offline}

        pid ->
          id = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
          send(pid, {:command, Arkab.Protocol.command(id, cmd, fields)})
          {:ok, id}
      end
    else
      {:error, :unknown_command}
    end
  end

  # --- removing ----------------------------------------------------------------

  @doc "Removes a bridge here; a connected one is told, one that dials in later too."
  def remove(%Bridge{} = bridge) do
    case link(bridge.id) do
      nil -> :ok
      pid -> send(pid, :leave)
    end

    forget(bridge)
  end

  @doc "The bridge is gone (it said `leave`, or `remove/1`): revoked, its boards with it."
  def forget(%Bridge{} = bridge) do
    bridge
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update!()

    for row <- rows(bridge), do: Boards.delete(row)
    Log.add(:info, "bridge.removed", %{name: bridge.name}, %{})
    notify()
    :ok
  end

  # --- boards ------------------------------------------------------------------

  @doc "The `port` of the row of the board the bridge calls `name`."
  def port(%Bridge{id: id}, name), do: "bridge-#{id}:#{name}"

  @doc "The rows of a bridge's boards."
  def rows(%Bridge{} = bridge) do
    prefix = port(bridge, "")

    for row <- Boards.list(),
        row.driver == "remote",
        String.starts_with?(row.port || "", prefix),
        do: row
  end

  @doc """
  The row that reads the board the bridge calls `name`: the one connected
  on its port, else one switched off there (the arbiter switched it off,
  and that is respected), else a new one - connected, and named after
  where it is.
  """
  def board_row(%Bridge{} = bridge, name) do
    port = port(bridge, name)
    here = Repo.all(from b in Board, where: b.driver == "remote" and b.port == ^port)

    case Enum.find(here, & &1.enabled) || List.first(here) do
      nil ->
        {_port, address} = Arkab.Protocol.parse_board_id(name)

        Boards.create(%{
          name: board_name(bridge, name),
          driver: "remote",
          port: port,
          address: address,
          options: %{},
          hall_id: bridge.hall_id || Halls.own_id()
        })

      row ->
        {:ok, row}
    end
  end

  defp board_name(bridge, name) do
    case Arkab.Protocol.parse_board_id(name) do
      {_port, nil} -> "#{bridge.name} #{Path.basename(name)}"
      {_port, address} -> "#{bridge.name} #{Arkab.Dgt.Bus.number(address)}"
    end
  end

  @doc """
  Puts a bridge in another hall (an admin's move: it takes the bridge's
  boards from one hall's people to another's). Its boards go with it, into
  the new hall's own tournament, without table numbers: those were the
  old hall's.
  """
  def move(%Bridge{} = bridge, hall_id) when is_integer(hall_id) do
    bridge = bridge |> Ecto.Changeset.change(hall_id: hall_id) |> Repo.update!()
    move_rows(bridge)
    Log.add(:info, "bridge.moved", %{name: bridge.name}, %{})
    notify()
    {:ok, bridge}
  end

  defp move_rows(%Bridge{hall_id: hall_id} = bridge) do
    tournament = Halls.local_tournament(hall_id)

    for row <- rows(bridge), row.hall_id != hall_id do
      row
      |> Ecto.Changeset.change(hall_id: hall_id)
      |> Repo.update!()
      |> Boards.update(%{tournament_id: tournament.id, table_no: nil, round: nil, board_no: nil})
    end

    :ok
  end

  @doc "What the server is called, for the bridge's page."
  def server_name, do: Settings.get("box_name") || "Alnasl"
end
