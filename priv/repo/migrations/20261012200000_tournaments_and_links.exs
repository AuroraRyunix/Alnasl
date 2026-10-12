defmodule Alnasl.Repo.Migrations.TournamentsAndLinks do
  use Ecto.Migration

  # A box used to serve one tournament, described by a handful of settings.
  # It now serves several, each a row: which pairing program it belongs to
  # (if any), its own results page, its own Lichess round, its own round in
  # play, its own tables. The settings of the one tournament a box had
  # become the first row - "this box's own" - and every board and game it
  # had goes with it, so a box that is upgraded in the middle of a weekend
  # carries on where it was.

  @moved ~w(server_url slug relay_key round snapshot snapshot_at
            lichess_round_id lichess_token lichess_round)

  def up do
    # A connect code of a pairing program: where it answers, and the secret
    # it wants to hear. One code reaches one tournament or a group of them.
    create table(:links) do
      add :root, :string, null: false
      add :secret, :text, null: false
      add :kind, :string
      add :group_name, :string
      add :etag, :string
      add :poll_seconds, :integer, null: false, default: 5
      add :server_name, :string
      add :server_version, :string
      add :state, :string, null: false, default: "new"
      add :error, :text
      add :last_ok_at, :utc_datetime
      add :last_try_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create table(:tournaments) do
      add :kind, :string, null: false, default: "local"
      add :link_id, references(:links, on_delete: :delete_all)
      add :remote_id, :integer
      add :name, :string
      add :label, :string
      add :state, :string
      # The version of the document held, and the one the listing last named.
      add :version, :string
      add :listed_version, :string
      add :document, :text
      add :document_at, :utc_datetime
      add :gone, :boolean, null: false, default: false
      # The round the box has on its boards, and the one the pairing program
      # last said was on.
      add :round, :integer, null: false, default: 1
      add :remote_round, :integer
      add :auto_start, :boolean, null: false, default: true
      add :table_from, :integer
      add :table_to, :integer
      add :server_url, :string, null: false, default: ""
      add :slug, :string, null: false, default: ""
      add :relay_key, :text, null: false, default: ""
      add :lichess_round_id, :string
      add :lichess_token, :text
      add :lichess_round, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournaments, [:link_id, :remote_id])

    flush()

    old = settings()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    repo().query!(
      """
      INSERT INTO tournaments
        (id, kind, name, document, document_at, round, server_url, slug, relay_key,
         lichess_round_id, lichess_token, lichess_round,
         gone, auto_start, inserted_at, updated_at)
      VALUES (1, 'local', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?)
      """,
      [
        get_in(old, ["snapshot", "tournament", "name"]),
        old["snapshot"] && Jason.encode!(document(old["snapshot"])),
        old["snapshot"] && old["snapshot_at"] && String.slice(old["snapshot_at"], 0, 19) <> "Z",
        int(old["round"]) || 1,
        text(old["server_url"]),
        text(old["slug"]),
        text(old["relay_key"]),
        blank(old["lichess_round_id"]),
        blank(old["lichess_token"]),
        int(old["lichess_round"]),
        now,
        now
      ]
    )

    repo().query!(
      "DELETE FROM settings WHERE key IN (" <> Enum.map_join(@moved, ",", &"'#{&1}'") <> ")"
    )

    alter table(:boards) do
      add :tournament_id, :integer, null: false, default: 1
    end

    # `remote_*`: the game as the pairing program names it - its id there and
    # the two player ids the box believes are playing it. `pairing_flag`: the
    # pairing changed under a game that had begun. `local`: a game that stays
    # on the box (the second game on a board, a game set aside).
    alter table(:games) do
      add :tournament_id, :integer, null: false, default: 1
      add :remote_game, :string
      add :remote_white, :integer
      add :remote_black, :integer
      add :pairing_flag, :string
      add :local, :boolean, null: false, default: false
    end

    flush()
    repo().query!("UPDATE games SET local = 1 WHERE game_no > 1")

    drop unique_index(:games, [:round, :board_no, :game_no])
    create unique_index(:games, [:tournament_id, :round, :board_no, :game_no])

    alter table(:outbox) do
      add :tournament_id, :integer, null: false, default: 1
    end

    create index(:outbox, [:tournament_id, :state, :id])

    # "Send again, whatever you hold": the arbiter's answer to a destination
    # that says it has something newer.
    alter table(:destination_cursors) do
      add :force, :boolean, null: false, default: false
    end
  end

  def down do
    %{rows: rows} =
      repo().query!("""
      SELECT server_url, slug, relay_key, round, lichess_round_id, lichess_token,
             lichess_round
      FROM tournaments WHERE id = 1
      """)

    with [[url, slug, key, round, l_id, l_token, l_round]] <- rows do
      for {key, value} <- [
            {"server_url", url},
            {"slug", slug},
            {"relay_key", key},
            {"round", round},
            {"lichess_round_id", l_id},
            {"lichess_token", l_token},
            {"lichess_round", l_round}
          ],
          value != nil do
        repo().query!("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [
          key,
          Jason.encode!(value)
        ])
      end
    end

    alter table(:destination_cursors), do: remove(:force)
    drop index(:outbox, [:tournament_id, :state, :id])
    alter table(:outbox), do: remove(:tournament_id)
    drop unique_index(:games, [:tournament_id, :round, :board_no, :game_no])

    alter table(:games) do
      remove :tournament_id
      remove :remote_game
      remove :remote_white
      remove :remote_black
      remove :pairing_flag
      remove :local
    end

    create unique_index(:games, [:round, :board_no, :game_no])
    alter table(:boards), do: remove(:tournament_id)
    drop table(:tournaments)
    drop table(:links)
  end

  defp settings do
    %{rows: rows} =
      repo().query!(
        "SELECT key, value FROM settings WHERE key IN (" <>
          Enum.map_join(@moved, ",", &"'#{&1}'") <> ")"
      )

    Map.new(rows, fn [key, json] ->
      {key,
       case Jason.decode(json || "null") do
         {:ok, value} -> value
         _broken -> nil
       end}
    end)
  end

  # The results server's public snapshot, which is what the box kept, in the
  # shape the box keeps pairings in now: players by an id (their number
  # there), boards that name two of them. A side the snapshot gave as a
  # bare name becomes a player of its own.
  defp document(%{} = snapshot) do
    players = for %{"no" => no} = p <- List.wrap(snapshot["players"]), is_integer(no), do: p
    known = MapSet.new(players, & &1["no"])

    {rounds, extra} =
      snapshot["rounds"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map_reduce([], fn round, extra ->
        {boards, extra} =
          round["boards"]
          |> List.wrap()
          |> Enum.filter(&(is_map(&1) and is_integer(&1["board"])))
          |> Enum.map_reduce(extra, fn board, extra ->
            {white, extra} = side(board["white"], known, extra)
            {black, extra} = side(board["black"], known, extra)

            {%{
               "game" => nil,
               "board" => board["board"],
               "label" => to_string(board["board"]),
               "kind" => "game",
               "white" => white,
               "black" => black,
               "result" => board["result"]
             }, extra}
          end)

        {%{"number" => round["number"], "boards" => boards}, extra}
      end)

    %{
      "tournament" => %{
        "name" => get_in(snapshot, ["tournament", "name"]),
        "site" => get_in(snapshot, ["tournament", "city"]),
        "city" => get_in(snapshot, ["tournament", "city"])
      },
      "players" =>
        Enum.map(players, fn p ->
          %{
            "id" => p["no"],
            "no" => p["no"],
            "name" => p["name"],
            "title" => p["title"],
            "rating" => p["rating"],
            "federation" => p["federation"],
            "fide_id" => p["fide_id"]
          }
        end) ++ Enum.reverse(extra),
      "rounds" => rounds
    }
  end

  defp side(no, known, extra) when is_integer(no) do
    if MapSet.member?(known, no), do: {no, extra}, else: {nil, extra}
  end

  defp side(name, _known, extra) when is_binary(name) and name != "" do
    id = 1_000_000 + length(extra)
    {id, [%{"id" => id, "no" => nil, "name" => name} | extra]}
  end

  defp side(_none, _known, extra), do: {nil, extra}

  defp int(n) when is_integer(n) and n > 0, do: n
  defp int(_other), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  defp blank(value) when is_binary(value) and value != "", do: value
  defp blank(_other), do: nil
end
