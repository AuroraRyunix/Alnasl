defmodule Alnasl.Tournament do
  @moduledoc """
  What the results server says about the tournament: its rounds, and for each
  round which players sit at which board. That is how the box learns that
  "board 7 of round 4" is these two people.

  It is read from the public snapshot (`GET /api/tournaments/:slug`, no key
  needed) and kept in the database, so the box still knows the pairings when
  the hall's network is gone.

  `test/0` is the "Test connection" button: it really asks the server, in
  three steps, and says which step failed and why in a form the site can put
  into words.
  """

  alias Alnasl.Settings

  @doc "Extra `Req` options (the tests' stub server)."
  def req_options, do: Application.get_env(:alnasl, :req_options, [])

  defp request(opts) do
    [retry: false, receive_timeout: 8_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  # --- the stored snapshot -----------------------------------------------------

  def snapshot, do: Settings.get("snapshot")

  @doc "Name and city, for PGN headers and the page title."
  def info do
    case snapshot() do
      %{"tournament" => %{} = t} -> %{name: t["name"], city: t["city"]}
      _none -> %{name: nil, city: nil}
    end
  end

  @doc "The round numbers the server has published."
  def rounds do
    case snapshot() do
      %{"rounds" => rounds} when is_list(rounds) ->
        rounds |> Enum.map(& &1["number"]) |> Enum.filter(&is_integer/1) |> Enum.sort()

      _none ->
        []
    end
  end

  @doc "The boards of a round: `[%{board, white, black, result}]` with player names."
  def boards(round) do
    with %{"rounds" => rounds} = snapshot <- snapshot(),
         %{"boards" => boards} <- Enum.find(rounds, &(&1["number"] == round)) do
      names = Map.new(snapshot["players"] || [], &{&1["no"], player_name(&1)})

      boards
      |> Enum.filter(&is_integer(&1["board"]))
      |> Enum.map(fn b ->
        %{
          board: b["board"],
          white: names[b["white"]] || side_name(b["white"]),
          black: names[b["black"]] || side_name(b["black"]),
          result: b["result"]
        }
      end)
      |> Enum.sort_by(& &1.board)
    else
      _none -> []
    end
  end

  def board(round, board_no), do: Enum.find(boards(round), &(&1.board == board_no))

  @doc """
  The two players of a board as the snapshot describes them:
  `%{white: player | nil, black: player | nil}`, each player a map with
  `:name`, `:title`, `:rating`, `:fide_id` and `:federation` (any of them
  `nil`). For destinations that want more than a name.
  """
  def players(round, board_no) do
    with %{"rounds" => rounds} = snapshot <- snapshot(),
         %{"boards" => boards} <- Enum.find(rounds, &(&1["number"] == round)),
         %{} = board <- Enum.find(boards, &(&1["board"] == board_no)) do
      by_no = Map.new(snapshot["players"] || [], &{&1["no"], &1})
      %{white: player(by_no[board["white"]]), black: player(by_no[board["black"]])}
    else
      _none -> %{white: nil, black: nil}
    end
  end

  defp player(%{"name" => name} = p) do
    %{
      name: name,
      title: if(p["title"] in [nil, ""], do: nil, else: p["title"]),
      rating: if(is_integer(p["rating"]) and p["rating"] > 0, do: p["rating"]),
      fide_id: if(is_integer(p["fide_id"]) and p["fide_id"] > 0, do: p["fide_id"]),
      federation: if(p["federation"] in [nil, ""], do: nil, else: p["federation"])
    }
  end

  defp player(_none), do: nil

  defp player_name(%{"name" => name} = player) do
    case player["title"] do
      title when is_binary(title) and title != "" -> "#{title} #{name}"
      _none -> name
    end
  end

  defp player_name(_other), do: nil

  defp side_name(name) when is_binary(name), do: name
  defp side_name(_other), do: nil

  # --- asking the server -------------------------------------------------------

  @doc """
  Fetches the snapshot and stores it. `{:ok, snapshot}` or `{:error, reason}`
  with `reason` one of `:not_configured`, `:unreachable`, `:not_found`,
  `{:http, status}`, `:not_json`.
  """
  def refresh do
    %{"server_url" => url, "slug" => slug} = Settings.get_many(~w(server_url slug))

    if url == "" or slug == "" do
      {:error, :not_configured}
    else
      case fetch(url, slug) do
        {:ok, snapshot} ->
          Settings.put("snapshot", snapshot)
          Settings.put("snapshot_at", DateTime.utc_now() |> DateTime.to_iso8601())
          {:ok, snapshot}

        error ->
          error
      end
    end
  end

  def fetch(url, slug) do
    case Req.get(request(url: url <> "/api/tournaments/" <> URI.encode(slug))) do
      {:ok, %{status: 200, body: %{"rounds" => _} = body}} -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :not_json}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _exception} -> {:error, :unreachable}
    end
  end

  @doc """
  Checks, against the server itself: that it answers, that the tournament is
  there, and that the relay key is taken for it. Returns
  `[{step, :ok | {:error, reason}} ...]` for the steps `:server`,
  `:tournament`, `:key`; a step after a failed one is `:skipped`.

  The key is tested with a request that carries no board: the server checks
  the credential first and then refuses the empty body (`422
  invalid_request`), which is the answer that proves the key - nothing is
  stored.
  """
  def test(url, slug, key) do
    server =
      case Req.get(request(url: url <> "/api/server")) do
        {:ok, %{status: status}} when status < 500 -> :ok
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, %{reason: reason}} -> {:error, {:unreachable, reason}}
        {:error, _other} -> {:error, {:unreachable, :unknown}}
      end

    tournament =
      cond do
        server != :ok -> :skipped
        slug == "" -> {:error, :no_slug}
        true -> with {:ok, snapshot} <- fetch(url, slug), do: {:ok, summary(snapshot)}
      end

    key_check =
      cond do
        not match?({:ok, _}, tournament) -> :skipped
        key in [nil, ""] -> {:error, :no_key}
        true -> test_key(url, slug, key)
      end

    [server: server, tournament: tournament, key: key_check]
  end

  defp summary(snapshot) do
    %{
      name: get_in(snapshot, ["tournament", "name"]),
      rounds: length(snapshot["rounds"] || []),
      boards:
        snapshot["rounds"]
        |> List.wrap()
        |> List.last()
        |> then(&length((&1 || %{})["boards"] || []))
    }
  end

  defp test_key(url, slug, key) do
    request =
      request(
        url: url <> "/api/tournaments/" <> URI.encode(slug) <> "/live",
        headers: [{"authorization", "Bearer " <> key}],
        json: %{}
      )

    case Req.post(request) do
      {:ok, %{status: 422}} ->
        :ok

      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401}} ->
        {:error, :key_refused}

      {:ok, %{status: 403, body: %{"error" => "relay_key_wrong_tournament"}}} ->
        {:error, :key_other_tournament}

      {:ok, %{status: 403, body: %{"error" => "relay_key_revoked"}}} ->
        {:error, :key_revoked}

      {:ok, %{status: 403, body: %{"error" => code}}} ->
        {:error, {:refused, code}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 503}} ->
        {:error, :paused}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, _exception} ->
        {:error, {:unreachable, :unknown}}
    end
  end
end
