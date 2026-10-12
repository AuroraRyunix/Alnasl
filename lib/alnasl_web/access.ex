defmodule AlnaslWeb.Access do
  @moduledoc """
  How to get another device - the arbiter's phone - onto the site: the
  addresses the box answers on in the hall's network, as text and as a QR
  code to point a camera at.

  The QR code is drawn here, on the box, as an inline SVG (`qr/1`): no
  picture is fetched from anywhere, so it works in a hall without internet.
  The encoding is the `eqrcode` package (MIT); the drawing is ours, always
  dark on white whatever the theme, because that is what cameras read.
  """

  use AlnaslWeb, :html

  alias Alnasl.Settings

  @doc """
  `%{lan?, port, urls}`: whether the box listens beyond itself at all
  (`ALNASL_LISTEN=lan`), the port, and an address for each IPv4 interface
  that is neither loopback nor link-local.
  """
  def info do
    http = AlnaslWeb.Endpoint.config(:http) || []
    port = http[:port] || 4040

    lan? =
      Application.get_env(:alnasl, :lan?, http[:ip] in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}])

    %{lan?: lan?, port: port, urls: Enum.map(addresses(), &"http://#{&1}:#{port}")}
  end

  @doc "The box's own addresses in the hall's network, as text."
  def addresses do
    case Application.get_env(:alnasl, :lan_addresses) do
      list when is_list(list) -> list
      _ask -> interfaces()
    end
  end

  defp interfaces do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces,
            flags = Keyword.get(opts, :flags, []),
            :up in flags,
            :loopback not in flags,
            {:addr, {a, b, c, d}} <- opts,
            {a, b} != {169, 254},
            a != 127,
            uniq: true,
            do: "#{a}.#{b}.#{c}.#{d}"

      _error ->
        []
    end
  end

  @doc """
  `text` as a QR code: `%{size, cells}` with `size` the side in modules
  including a quiet zone of four, and `cells` the dark modules as `{x, y}`.
  `nil` when the text cannot be encoded.
  """
  def qr(text) when is_binary(text) do
    %{matrix: matrix} = EQRCode.encode(text)
    rows = Tuple.to_list(matrix)

    cells =
      for {row, y} <- Enum.with_index(rows),
          {cell, x} <- Enum.with_index(Tuple.to_list(row)),
          cell == 1,
          do: {x + 2, y + 2}

    # The encoder leaves two modules of margin; the standard asks for four.
    %{size: length(rows) + 4, cells: cells}
  rescue
    _error -> nil
  end

  @doc "The panel: addresses, the QR code of the first, and what to know about the PIN."
  attr :id, :string, required: true
  attr :path, :string, default: "/", doc: "where on the site the code should lead"

  def phone(assigns) do
    info = info()
    url = List.first(info.urls)

    assigns =
      assign(assigns,
        info: info,
        url: url && url <> assigns.path,
        code: url && qr(url <> assigns.path),
        pin_set?: Settings.pin_set?()
      )

    ~H"""
    <div id={@id} class="phone-access">
      <%= if @url do %>
        <div :if={@code} id={"#{@id}-qr"} class="qr">
          <svg
            viewBox={"0 0 #{@code.size} #{@code.size}"}
            role="img"
            aria-label={gettext("QR code of %{url}", url: @url)}
            shape-rendering="crispEdges"
          >
            <rect width={@code.size} height={@code.size} fill="#ffffff" />
            <rect :for={{x, y} <- @code.cells} x={x} y={y} width="1" height="1" fill="#000000" />
          </svg>
        </div>
        <div class="stack">
          <p>
            {gettext("Open this address on your phone, or point its camera at the code:")}
          </p>
          <ul id={"#{@id}-urls"} class="addresses">
            <li :for={u <- @info.urls} class="mono">{u <> @path}</li>
          </ul>
          <p :if={!@info.lan?} id={"#{@id}-local-only"} class="note">
            <.badge tone="warn" icon="warning">{gettext("Not reachable yet")}</.badge>
            {gettext(
              "This box answers only itself, so a phone gets no answer. Setup, \"Access from other machines\": set a PIN, let other machines in, and start Alnasl again."
            )}
          </p>
          <p :if={@pin_set?} id={"#{@id}-pin-set"} class="note">
            {gettext("The phone will be asked for the PIN once.")}
          </p>
          <p :if={!@pin_set?} id={"#{@id}-pin-hint"} class="note">
            <.badge tone="warn" icon="warning">{gettext("No PIN")}</.badge>
            {gettext(
              "Anybody on the hall's network who opens this address can renumber the boards. Set a PIN in Setup before the hall fills up."
            )}
            <.link navigate={~p"/setup"}>{gettext("Go to Setup")}</.link>
          </p>
        </div>
      <% else %>
        <p id={"#{@id}-none"} class="note">
          {gettext(
            "The box has no address in a network just now. Connect it to the hall's network (cable or Wi-Fi) and open this page again."
          )}
        </p>
      <% end %>
    </div>
    """
  end
end
