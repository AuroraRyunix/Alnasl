defmodule Alnasl.OpenPairings.Connect do
  @moduledoc """
  Connecting an OpenPairings account instead of pasting a code
  (`docs/board-link-api.md` there, "Connecting an account").

  The arbiter's browser is sent to `<openpairings>/boards/connect` with the
  address to come back to, a `state` this box keeps in the browser's
  session, and the name to show. There, signed in, they press Allow; the
  browser comes back with a grant, and the box - not the browser - trades
  the grant for an `oplu_` code (`redeem/2`). From then on the code is an
  ordinary link (`Alnasl.OpenPairings.add_code/2`): the poller, the sync and
  the duplicate check do not know it arrived differently.

  The address of OpenPairings is what the arbiter typed, or the last one
  used, or `ALNASL_OPENPAIRINGS_URL` (`config :alnasl, :openpairings_url`).
  A desktop copy is `http://127.0.0.1:<port>`; nothing here insists on
  https or on a public name.
  """

  alias Alnasl.OpenPairings.Client
  alias Alnasl.Settings

  @setting "openpairings_url"

  @doc "The address to offer: the last one used, else the configured one, else nil."
  def default_address do
    Settings.get(@setting) || Application.get_env(:alnasl, :openpairings_url)
  end

  @doc "Remembers the address for next time."
  def remember(address) when is_binary(address), do: Settings.put(@setting, address)

  @doc """
  What was typed, as the address of an OpenPairings: `{:ok,
  "https://pairings.example.org"}` or `{:error, :not_an_address}`. A bare
  name gets `https://`; a pasted connect code or API root is cut back to
  the server.
  """
  def normalize(text) do
    text = String.replace(text || "", ~r/\s+/u, "")
    text = text |> String.split("#", parts: 2) |> hd()
    text = if text =~ ~r{\A[a-zA-Z][a-zA-Z0-9+.\-]*://}, do: text, else: "https://" <> text

    text =
      text
      |> String.replace(~r{/api/boards/v1/?\z}, "")
      |> String.trim_trailing("/")

    case URI.parse(text) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, text}

      _other ->
        {:error, :not_an_address}
    end
  end

  @doc "Where to send the browser."
  def connect_url(address, return_to, state, box) do
    address <>
      "/boards/connect?" <>
      URI.encode_query(%{"return_to" => return_to, "state" => state, "box" => box})
  end

  @doc "A fresh `state`."
  def new_state, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc """
  Trades a grant for a connect code: `{:ok, code_text}`, or `{:error,
  reason}` with `reason` one of `:expired` (used, run out or refused),
  `{:rate_limited, ms}`, `:not_the_api`, `{:http, status}`, `{:unreachable,
  why}`.
  """
  def redeem(address, grant) when is_binary(address) and is_binary(grant) do
    request =
      [
        url: address <> "/api/boards/v1/grant",
        json: %{"grant" => grant},
        retry: false,
        receive_timeout: 8_000
      ]
      |> Keyword.merge(Client.req_options())
      |> Req.new()

    case Req.post(request) do
      {:ok, %{status: 200, body: %{"code" => code}}} when is_binary(code) ->
        if String.contains?(code, "#"), do: {:ok, code}, else: {:error, :not_the_api}

      {:ok, %{status: 401}} ->
        {:error, :expired}

      {:ok, %{status: 429} = response} ->
        wait =
          with [value | _] <- Req.Response.get_header(response, "retry-after"),
               {seconds, _} <- Integer.parse(value) do
            seconds * 1000
          else
            _none -> 60_000
          end

        {:error, {:rate_limited, wait}}

      {:ok, %{status: status}} when status in [200, 404] ->
        {:error, :not_the_api}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, %{reason: reason}} ->
        {:error, {:unreachable, reason}}

      {:error, _other} ->
        {:error, {:unreachable, :unknown}}
    end
  end
end
