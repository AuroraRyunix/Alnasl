defmodule Alnasl.Destination.LichessApi do
  @moduledoc """
  Everything Alnasl knows about Lichess's HTTP API, in one place: the
  addresses, the headers, and how the answers are read. Nothing else in
  Alnasl builds a Lichess URL.

  Source: the Lichess API documentation (https://lichess.org/api), section
  "Broadcasts", operation "Push PGN to a broadcast round", and section
  "Account". Written from that description and not yet run against
  lichess.org itself: what is marked ASSUMED below is what a first real
  broadcast should confirm.

  | what | request | how sure |
  |---|---|---|
  | push | `POST /api/broadcast/round/{roundId}/push`, body: the PGN of one or more games as text, `Authorization: Bearer <token>`; the token needs the `study:write` scope and its owner must be allowed to edit the broadcast | documented |
  | the body's content type | `application/x-chess-pgn` | ASSUMED - the documentation calls the body plain text; Lichess reads it as text whatever it is called |
  | the answer to a push | `200 {"games": [{"tags": {...}, "moves": n} or {"tags": {...}, "error": "..."}]}`, one entry per game of the body | ASSUMED in its details: the list and the per-game `error` are documented, that the order is the body's order is not said in so many words |
  | a game pushed again | Lichess finds the game of the round with the same players and brings it up to the PGN: moves added, and a line that now differs replaced | ASSUMED - the documented use is adding moves; that a correction replaces moves already shown is how the broadcast sync is described, not something this code has seen |
  | a push that is refused | `400` with `{"error": "..."}` (for one: a round that is set up to fetch from a URL instead), `401` a bad token, `403` not this token's broadcast, `404` no such round | ASSUMED which status goes with which cause; all four are treated alike - wait, say what Lichess said, try again |
  | too many requests | `429`; Lichess asks for a full minute's silence | documented for the API as a whole |
  | who am I | `GET /api/account` with the token: `200 {"id", "username", ...}`, `401` for a bad token | documented |
  | the token's scopes | `POST /api/token/test`, body: the token as text; `200 {"<token>": {"scopes": "study:write,...", "userId": ...} or null}` | ASSUMED in the exact shape of the answer; a shape this code does not know is reported as "could not be checked", never as a failure |
  | the round | `GET /api/broadcast/-/-/{roundId}`: `200 {"round": {"name", ...}, "tour": {"name", ...}}`, `404` for an id that is no round | ASSUMED - the two path segments before the id are slugs Lichess says it ignores |

  The base address is a setting (`lichess_url`, `https://lichess.org`), so a
  test server or a Lichess of one's own can stand in.
  """

  alias Alnasl.Settings

  @default_base "https://lichess.org"
  @content_type "application/x-chess-pgn"

  def default_base, do: @default_base

  @doc "Extra `Req` options (the tests' stand-in for Lichess)."
  def req_options, do: Application.get_env(:alnasl, :lichess_req_options, [])

  def base do
    case Settings.get("lichess_url") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _default -> @default_base
    end
  end

  def push_url(base, round_id), do: base <> "/api/broadcast/round/" <> round_id <> "/push"
  def account_url(base), do: base <> "/api/account"
  def token_test_url(base), do: base <> "/api/token/test"
  def round_url(base, round_id), do: base <> "/api/broadcast/-/-/" <> round_id

  @doc "Where a person looks at the round."
  def round_page(base, round_id), do: base <> "/broadcast/-/-/" <> round_id

  defp request(opts) do
    [retry: false, receive_timeout: 10_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  defp bearer(token), do: {"authorization", "Bearer " <> token}

  @doc """
  Reads what an arbiter pastes: the round's id, or a link to the round
  (`https://lichess.org/broadcast/<tournament>/<round>/<id>`, with or without
  `/edit` behind it). `{:ok, id}` or `:error`. A round id is eight letters
  and digits.
  """
  def parse_round(text) do
    text = String.trim(text || "")

    segments =
      case URI.parse(text) do
        %URI{scheme: scheme, path: path} when scheme in ["http", "https"] and is_binary(path) ->
          path |> String.split("/", trim: true) |> Enum.reverse()

        _bare ->
          [text]
      end

    case Enum.find(segments, &(&1 not in ["edit", "push"])) do
      id when is_binary(id) -> if id =~ ~r/^[A-Za-z0-9]{8}$/, do: {:ok, id}, else: :error
      nil -> :error
    end
  end

  @doc """
  Pushes `pgn` (one or more games) to the round. Returns

  - `{:ok, [:ok | {:error, message}]}` - one answer per game, in order
    (an answer this code cannot read counts every game as taken);
  - `{:retry, reason, wait_ms | nil}`, `{:blocked, reason}` - as
    `Alnasl.Destination` says.
  """
  def push(base, round_id, token, pgn) do
    request =
      request(
        url: push_url(base, round_id),
        headers: [bearer(token), {"content-type", @content_type}],
        body: pgn
      )

    case Req.post(request) do
      {:ok, %{status: 200, body: %{"games" => games}}} when is_list(games) ->
        {:ok,
         Enum.map(games, fn
           %{"error" => error} when is_binary(error) -> {:error, error}
           _taken -> :ok
         end)}

      {:ok, %{status: 200}} ->
        {:ok, []}

      {:ok, %{status: 429} = response} ->
        {:retry, :rate_limited, retry_after(response) || 60_000}

      {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
        {:blocked, {:lichess, status, message(body)}}

      {:ok, %{status: status}} ->
        {:retry, {:http, status, nil}, nil}

      {:error, %{reason: reason}} ->
        {:retry, {:unreachable, reason}, nil}

      {:error, _exception} ->
        {:retry, {:unreachable, :unknown}, nil}
    end
  end

  @doc """
  The "Test" button: asks Lichess who the token belongs to, whether it may
  write studies, and whether the round is there. Nothing is changed on
  Lichess. `[account: r, scope: r, round: r]` with each `r` one of
  `{:ok, detail}`, `{:error, reason}`, `:unknown` (asked, answer not
  understood) or `:skipped`.
  """
  def test(base, round_id, token) do
    account =
      if token in [nil, ""] do
        {:error, :no_token}
      else
        case Req.get(request(url: account_url(base), headers: [bearer(token)])) do
          {:ok, %{status: 200, body: %{"username" => name}}} -> {:ok, name}
          {:ok, %{status: 200}} -> {:ok, nil}
          {:ok, %{status: 401}} -> {:error, :token_refused}
          {:ok, %{status: 429}} -> {:error, :rate_limited}
          {:ok, %{status: status}} -> {:error, {:http, status}}
          {:error, %{reason: reason}} -> {:error, {:unreachable, reason}}
          {:error, _other} -> {:error, {:unreachable, :unknown}}
        end
      end

    scope = if match?({:ok, _}, account), do: scope(base, token), else: :skipped

    round =
      cond do
        match?({:error, {:unreachable, _}}, account) -> :skipped
        round_id in [nil, ""] -> {:error, :no_round}
        true -> round(base, round_id, token)
      end

    [account: account, scope: scope, round: round]
  end

  defp scope(base, token) do
    request =
      request(url: token_test_url(base), headers: [{"content-type", "text/plain"}], body: token)

    with {:ok, %{status: 200, body: %{} = body}} <- Req.post(request),
         %{"scopes" => scopes} when is_binary(scopes) <- body[token] do
      if "study:write" in String.split(scopes, ","),
        do: {:ok, scopes},
        else: {:error, {:scope_missing, scopes}}
    else
      _unreadable -> :unknown
    end
  end

  defp round(base, round_id, token) do
    headers = if token in [nil, ""], do: [], else: [bearer(token)]

    case Req.get(request(url: round_url(base, round_id), headers: headers)) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, %{round: get_in(body, ["round", "name"]), tour: get_in(body, ["tour", "name"])}}

      {:ok, %{status: 200}} ->
        :unknown

      {:ok, %{status: 404}} ->
        {:error, :round_not_found}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :round_refused}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, %{reason: reason}} ->
        {:error, {:unreachable, reason}}

      {:error, _other} ->
        {:error, {:unreachable, :unknown}}
    end
  end

  defp message(%{"error" => error}) when is_binary(error), do: String.slice(error, 0, 300)
  defp message(text) when is_binary(text), do: String.slice(text, 0, 300)
  defp message(_other), do: nil

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      seconds * 1000
    else
      _none -> nil
    end
  end
end
