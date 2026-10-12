defmodule AlnaslWeb.SiteComponents do
  @moduledoc """
  Links to the results site, and the QR code of its live page.

  A link to somewhere else opens in a new tab and says so with `rel`: the
  arbiter's tab with the boards in it is not to be replaced by a spectator's
  page. Addresses come from `Alnasl.ResultsSite`.
  """

  use Phoenix.Component
  use Gettext, backend: AlnaslWeb.Gettext

  import AlnaslWeb.CoreComponents, only: [icon: 1]

  @doc "A link in the text that opens another site in a new tab."
  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def site_link(assigns) do
    ~H"""
    <a id={@id} href={@href} target="_blank" rel="noopener" class={["site-link", @class]}>
      {render_slot(@inner_block)}<.icon name="external" />
    </a>
    """
  end

  @doc """
  The text `text` as a QR code, drawn here (`AlnaslWeb.Access.qr/1`): no
  picture to fetch, nothing leaves the box. Dark on white, always.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :code, :map, default: nil, doc: "an `Access.qr/1` result, when the caller keeps it"

  def qr_code(assigns) do
    assigns = assign(assigns, :code, assigns.code || AlnaslWeb.Access.qr(assigns.text))

    ~H"""
    <div :if={@code} id={@id} class="qr site-qr-code">
      <svg
        viewBox={"0 0 #{@code.size} #{@code.size}"}
        role="img"
        aria-label={gettext("QR code of %{url}", url: @text)}
        shape-rendering="crispEdges"
      >
        <rect width={@code.size} height={@code.size} fill="#ffffff" />
        <rect :for={{x, y} <- @code.cells} x={x} y={y} width="1" height="1" fill="#000000" />
      </svg>
    </div>
    """
  end

  @doc "Why a tournament has no link, in a few words (`Alnasl.ResultsSite.why_not/1`)."
  def no_site_reason(:no_site), do: gettext("No results site for this tournament yet.")
  def no_site_reason(:no_slug), do: gettext("The results page has no short name yet.")
end
