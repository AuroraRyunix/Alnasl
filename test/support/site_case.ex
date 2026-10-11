defmodule AlnaslWeb.SiteCase do
  @moduledoc """
  For tests of the management site: everything `Alnasl.HallCase` sets up (a
  results server, a tournament of four boards, quick tracker timings), a
  `conn` that comes from the box itself, and the LiveView test helpers.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Alnasl.HallCase
      use AlnaslWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import AlnaslWeb.SiteCase

      @endpoint AlnaslWeb.Endpoint
    end
  end

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Waits until the rendered view satisfies `fun` (given the HTML), and returns the HTML."
  def eventually_html(view, fun, timeout \\ 5_000) do
    Alnasl.HallCase.eventually(
      fn ->
        html = Phoenix.LiveViewTest.render(view)
        fun.(html) && html
      end,
      timeout
    )
  end
end
