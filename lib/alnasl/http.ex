defmodule Alnasl.Http do
  @moduledoc """
  What every request the box makes has in common: no retries of `Req`'s own
  (each caller has its own patience), a timeout, and - in the tests - the
  stub server in place of the network.
  """

  @doc "Extra `Req` options (the tests' stub server)."
  def req_options, do: Application.get_env(:alnasl, :req_options, [])

  @doc "A request with the box's defaults, `opts` over them."
  def request(opts) do
    [retry: false, receive_timeout: 8_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options())
    |> Req.new()
  end
end
