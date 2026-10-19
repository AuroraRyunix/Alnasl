defmodule Alnasl.Http do
  @moduledoc """
  What every request the box makes has in common: no retries of `Req`'s own
  (each caller has its own patience), a timeout, and - in the tests - the
  stub server in place of the network.

  ## Addresses an arbiter supplies

  The pairing program and the results server are named by the arbiter, and a
  desktop copy of OpenPairings is `http://127.0.0.1:4000`, so on a box any
  address is allowed. The hosted server (`Alnasl.Accounts.server?/0`) is not
  somebody's desk: from there an address that names the server itself, its
  neighbours or its network is not a pairing program but a way to knock on
  doors. `guard/1` refuses, on the server, a host that resolves to a loopback,
  private, link-local or otherwise internal address; it looks again at every
  redirect, since that is a request like any other.
  """

  import Bitwise

  @doc "Extra `Req` options (the tests' stub server)."
  def req_options, do: Application.get_env(:alnasl, :req_options, [])

  @doc "A request with the box's defaults, `opts` over them."
  def request(opts) do
    [retry: false, receive_timeout: 8_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options())
    |> Req.new()
    |> guard()
  end

  @doc """
  Makes `request` refuse, on the hosted server, a host that is not on the
  public internet. The answer is `{:error, %Req.TransportError{reason:
  :forbidden_address}}`, which the callers read as an address that cannot
  be reached.
  """
  def guard(%Req.Request{} = request) do
    Req.Request.prepend_request_steps(request, address_guard: &check_step/1)
  end

  defp check_step(%Req.Request{url: %URI{host: host}} = request) do
    if Alnasl.Accounts.server?() and forbidden_host?(host) do
      Req.Request.halt(request, Req.TransportError.exception(reason: :forbidden_address))
    else
      request
    end
  end

  @doc """
  Does `host` resolve to an address that is not for a request from the
  server: loopback, private, link-local, unspecified, multicast, shared
  (carrier-grade NAT) or the like? A name that does not
  resolve is not forbidden - nothing can be reached through it either.
  """
  def forbidden_host?(host) when is_binary(host) do
    charlist =
      host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.to_charlist()

    addresses =
      case :inet.parse_address(charlist) do
        {:ok, ip} -> [ip]
        {:error, _name} -> resolve(charlist)
      end

    Enum.any?(addresses, &internal?/1)
  end

  def forbidden_host?(_none), do: true

  defp resolve(name) do
    for family <- [:inet, :inet6],
        {:ok, addresses} <- [:inet.getaddrs(name, family)],
        address <- addresses,
        do: address
  end

  @doc false
  def internal?({a, b, c, _d}) do
    a in [0, 10, 127] or a >= 224 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168) or
      (a == 192 and b == 0 and c in [0, 2]) or
      (a == 198 and b in [18, 19]) or
      (a == 198 and b == 51 and c == 100) or
      (a == 203 and b == 0 and c == 113)
  end

  # IPv4 carried in IPv6 (::ffff:a.b.c.d, and the deprecated ::a.b.c.d, which
  # takes :: and ::1 along) is judged as the IPv4 address it carries.
  def internal?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: internal?(embedded(hi, lo))
  def internal?({0, 0, 0, 0, 0, 0, hi, lo}), do: internal?(embedded(hi, lo))

  def internal?({a, _b, _c, _d, _e, _f, _g, _h}) do
    # fc00::/7 unique local, fe80::/10 link-local, ff00::/8 multicast.
    (a &&& 0xFE00) == 0xFC00 or (a &&& 0xFFC0) == 0xFE80 or (a &&& 0xFF00) == 0xFF00
  end

  def internal?(_other), do: true

  defp embedded(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
end
