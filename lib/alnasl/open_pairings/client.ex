defmodule Alnasl.OpenPairings.Client do
  @moduledoc """
  The four requests of the board link (`docs/board-link-api.md` in
  OpenPairings, API version 1), and what their answers mean. Nothing here
  remembers anything: it is given a link and says what the pairing program
  said.

  | | |
  |---|---|
  | `listing/2` | `GET <root>/link`, with the `ETag` of the last answer |
  | `tournament/3` | `GET <root>/tournaments/:id`, with the version held |
  | `box/2` | `POST <root>/box`: the box's name, version and board counts |
  | `report/3` | `POST <root>/tournaments/:id/games`: games, at most 64 |

  Every request carries the secret as a bearer token and says which box is
  asking (`X-Board-Box`, `X-Board-Box-Version`).

  ## What comes back when it did not work

  | reason | |
  |---|---|
  | `:unauthorized` | 401: the code is wrong or was withdrawn. Not to be tried again in a loop |
  | `:tournament_not_found` | 404: this code does not (or no longer) reach that tournament |
  | `{:rate_limited, wait_ms}` | 429 |
  | `{:refused, status, code, detail}` | another 4xx: this request is wrong and stays wrong |
  | `{:http, status}` | 5xx, or an answer the contract does not know |
  | `:not_the_api` | 200 with something that is not the answer: a hotel's login page, another program on that port |
  | `{:unreachable, reason}` | no answer at all |
  """

  alias Alnasl.Tournaments.Link

  @doc "Extra `Req` options (the tests' fake pairing program)."
  def req_options, do: Application.get_env(:alnasl, :openpairings_req_options, [])

  @doc "The version this box reports, and the API version it speaks."
  def box_version, do: to_string(Application.spec(:alnasl, :vsn) || "0")
  def api, do: 1

  defp request(%Link{} = link, path, opts) do
    [
      url: link.root <> path,
      headers:
        [
          {"authorization", "Bearer " <> link.secret},
          {"x-board-box", String.slice(Alnasl.Settings.get("box_name") || "Alnasl", 0, 80)},
          {"x-board-box-version", String.slice(box_version(), 0, 40)}
        ] ++ Keyword.get(opts, :headers, []),
      retry: false,
      receive_timeout: 8_000
    ]
    |> Keyword.merge(Keyword.delete(opts, :headers))
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  @doc "`{:ok, listing, etag}`, `:not_modified` or `{:error, reason}`."
  def listing(%Link{} = link, etag \\ nil) do
    case Req.get(request(link, "/link", headers: if_none_match(etag))) do
      {:ok, %{status: 200, body: %{"tournaments" => list} = body} = response}
      when is_list(list) ->
        {:ok, body, etag_of(response)}

      {:ok, %{status: 304}} ->
        :not_modified

      other ->
        error(other)
    end
  end

  @doc "`{:ok, document}`, `:not_modified` or `{:error, reason}`."
  def tournament(%Link{} = link, id, version \\ nil) do
    case Req.get(request(link, "/tournaments/#{id}", headers: if_none_match(version))) do
      {:ok, %{status: 200, body: %{"rounds" => rounds, "version" => _} = body}}
      when is_list(rounds) ->
        {:ok, body}

      {:ok, %{status: 304}} ->
        :not_modified

      other ->
        error(other)
    end
  end

  @doc "`:ok` or `{:error, reason}`. `boards` is `%{tournament id there => how many boards}`."
  def box(%Link{} = link, boards) do
    body = %{
      "name" => String.slice(Alnasl.Settings.get("box_name") || "Alnasl", 0, 80),
      "version" => String.slice(box_version(), 0, 40),
      "boards" => Map.new(boards, fn {id, count} -> {to_string(id), count} end)
    }

    case Req.post(request(link, "/box", json: body)) do
      {:ok, %{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @doc """
  Reports games of one tournament. `{:ok, results}` with one result per
  game, in order - `%{"status" => "ok", "applied" => ..., "seq" => ...}` or
  `%{"status" => "error", "error" => code, "detail" => ...}` - or
  `{:error, reason}` when the request as a whole was not taken.
  """
  def report(%Link{} = link, id, games) when is_list(games) do
    case Req.post(request(link, "/tournaments/#{id}/games", json: %{"games" => games})) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      other ->
        error(other)
    end
  end

  defp if_none_match(nil), do: []
  defp if_none_match(etag), do: [{"if-none-match", ~s("#{etag}")}]

  defp etag_of(response) do
    case Req.Response.get_header(response, "etag") do
      [value | _] -> value |> String.trim_leading("W/") |> String.trim("\"")
      [] -> nil
    end
  end

  defp error({:ok, %{status: 200}}), do: {:error, :not_the_api}
  defp error({:ok, %{status: 401}}), do: {:error, :unauthorized}

  defp error({:ok, %{status: 404, body: %{"error" => "tournament_not_found"}}}),
    do: {:error, :tournament_not_found}

  defp error({:ok, %{status: 429} = response}) do
    wait =
      with [value | _] <- Req.Response.get_header(response, "retry-after"),
           {seconds, _} <- Integer.parse(value) do
        seconds * 1000
      else
        _none -> 60_000
      end

    {:error, {:rate_limited, wait}}
  end

  defp error({:ok, %{status: status, body: %{"error" => code} = body}})
       when status in 400..499 and is_binary(code),
       do: {:error, {:refused, status, code, body["detail"]}}

  # A 404 that is not the API's own: the address is not a board link.
  defp error({:ok, %{status: 404}}), do: {:error, :not_the_api}
  defp error({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp error({:error, %{reason: reason}}), do: {:error, {:unreachable, reason}}
  defp error({:error, _other}), do: {:error, {:unreachable, :unknown}}
end
