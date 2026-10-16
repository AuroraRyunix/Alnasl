defmodule Alnasl.OpenPairings.Code do
  @moduledoc """
  A connect code, read: one line of text that OpenPairings shows once
  (Settings, Live boards) and as a QR code holding the same text.

      https://pairings.example.org/api/boards/v1#oplt_Zq3...

  Everything before the first `#` is where the API answers; everything
  after it is the secret. `oplt_` is a code for one tournament, `oplg_` for
  a group of them, `oplu_` for everything an account may edit (it arrives
  through `Alnasl.OpenPairings.Connect`, not by pasting, though pasting one
  works too) - the box does not care which, the listing says.

  The address is used as it is written. A desktop copy of OpenPairings
  gives `http://127.0.0.1:<port>/...`, which is right for a box program on
  the same computer and for nothing else; the box does not second-guess it.

  What an arbiter pastes has been through a phone, a chat program or a mail:
  spaces and line breaks anywhere in it are dropped, neither half has any.
  """

  @type t :: %{root: String.t(), secret: String.t(), kind: String.t() | nil}

  @doc """
  `{:ok, %{root, secret, kind}}`, or `{:error, reason}` with `reason` one of
  `:empty`, `:no_secret` (no `#`, or nothing after it), `:not_an_address`
  (what is before the `#` is not an http or https address).
  """
  @spec parse(String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def parse(text) do
    text = String.replace(text || "", ~r/\s+/u, "")

    case String.split(text, "#", parts: 2) do
      [""] ->
        {:error, :empty}

      [_no_hash] ->
        {:error, :no_secret}

      [_root, ""] ->
        {:error, :no_secret}

      [root, secret] ->
        root = String.trim_trailing(root, "/")

        case URI.parse(root) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            {:ok, %{root: root, secret: secret, kind: kind(secret)}}

          _other ->
            {:error, :not_an_address}
        end
    end
  end

  defp kind("oplt_" <> _rest), do: "tournament"
  defp kind("oplg_" <> _rest), do: "group"
  defp kind("oplu_" <> _rest), do: "account"
  defp kind(_opaque), do: nil

  @doc "Is the address one that only this computer can reach?"
  def loopback?(root) do
    case URI.parse(root || "") do
      %URI{host: host} when host in ["127.0.0.1", "localhost", "[::1]", "::1"] -> true
      %URI{host: "127." <> _rest} -> true
      _other -> false
    end
  end

  @doc "The host and port of an address, for showing: `pairings.example.org`, `127.0.0.1:4000`."
  def host(root) do
    case URI.parse(root || "") do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) ->
        if port in [nil, 80, 443] or URI.default_port(scheme) == port,
          do: host,
          else: "#{host}:#{port}"

      _other ->
        root
    end
  end
end
