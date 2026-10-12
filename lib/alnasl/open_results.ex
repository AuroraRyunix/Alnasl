defmodule Alnasl.OpenResults do
  @moduledoc """
  The results server, asked whether a results page and a relay key are
  right: the "Test connection" of a tournament whose results page was typed
  in on the box.

  That is all the box asks of it. The link to the results server is one
  way - moves out (`Alnasl.Outbox`). Who plays whom comes from the pairing
  program (`Alnasl.OpenPairings`) or from the arbiter; the box used to read
  the pairings from the results server's public page and does not any more.
  """

  alias Alnasl.Http

  @doc """
  Checks, against the server itself, that it answers and that the relay key
  is taken for the tournament. Returns `[server: result, key: result]` with
  `result` `:ok`, `{:error, reason}` or `:skipped` (the step before it
  failed).

  The key is tested with a request that carries no board: the server checks
  the credential first and then refuses the empty body (`422
  invalid_request`), which is the answer that proves the key - nothing is
  stored. A tournament that is not there is found out the same way (`404`).
  """
  def test(url, slug, key) do
    server =
      case Req.get(Http.request(url: url <> "/api/server")) do
        {:ok, %{status: status}} when status < 500 -> :ok
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, %{reason: reason}} -> {:error, {:unreachable, reason}}
        {:error, _other} -> {:error, {:unreachable, :unknown}}
      end

    key_check =
      cond do
        server != :ok -> :skipped
        slug == "" -> {:error, :no_slug}
        key in [nil, ""] -> {:error, :no_key}
        true -> test_key(url, slug, key)
      end

    [server: server, key: key_check]
  end

  defp test_key(url, slug, key) do
    request =
      Http.request(
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
