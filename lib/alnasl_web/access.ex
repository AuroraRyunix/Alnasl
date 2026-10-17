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

  @doc """
  The panel: addresses, the QR code of the first, and what to know about the
  PIN. With accounts, the code is a sign-in link instead (`signin`, made by
  the "phone_signin" event every page answers): good once, for five
  minutes, so a photo of the screen is not a key to the hall. On the server
  the address is the server's public one, not the machine's own.
  """
  attr :id, :string, required: true
  attr :path, :string, default: "/", doc: "where on the site the code should lead"
  attr :accounts?, :boolean, default: false, doc: "login is on: show a sign-in code"
  attr :signin, :map, default: nil, doc: "`%{path, expires_at}` of the sign-in link on show"

  def phone(assigns) do
    info = info()

    info =
      if Alnasl.Accounts.server?(),
        do: %{info | lan?: true, urls: [AlnaslWeb.Endpoint.url()]},
        else: info

    url = List.first(info.urls)
    target = if assigns.signin, do: assigns.signin.path, else: assigns.path
    show_code? = not assigns.accounts? or assigns.signin != nil

    assigns =
      assign(assigns,
        info: info,
        url: url && url <> target,
        code: url && show_code? && qr(url <> target),
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
          <%= if @accounts? do %>
            <%= if @signin do %>
              <p>{gettext("Point the phone's camera at the code: it signs the phone in as you.")}</p>

              <p id={"#{@id}-signin-expiry"} class="note">
                {gettext(
                  "Good once, until %{time} (UTC). Do not leave it on a screen others photograph.",
                  time: Calendar.strftime(@signin.expires_at, "%H:%M")
                )}
              </p>
            <% else %>
              <p>
                {gettext(
                  "A phone signs in with its own account, or with a sign-in code from here: a QR code that signs it in as you, once, within five minutes."
                )}
              </p>
            <% end %>

            <div>
              <.button
                id={"#{@id}-signin"}
                phx-click="phone_signin"
                phx-value-to={@path}
                icon="send"
              >
                {if @signin, do: gettext("A fresh code"), else: gettext("Make a sign-in code")}
              </.button>
            </div>

            <ul id={"#{@id}-urls"} class="addresses">
              <li :for={u <- @info.urls} class="mono">{u <> @path}</li>
            </ul>
          <% else %>
            <p>
              {gettext("Open this address on your phone, or point its camera at the code:")}
            </p>

            <ul id={"#{@id}-urls"} class="addresses">
              <li :for={u <- @info.urls} class="mono">{u <> @path}</li>
            </ul>
          <% end %>

          <p :if={!@info.lan?} id={"#{@id}-local-only"} class="note">
            <.badge tone="warn" icon="warning">{gettext("Not reachable yet")}</.badge>
            {gettext(
              "This box answers only itself, so a phone gets no answer. Setup, Access, \"Access from other machines\": set a PIN, let other machines in, and start Alnasl again."
            )}
          </p>

          <p :if={@pin_set? and !@accounts?} id={"#{@id}-pin-set"} class="note">
            {gettext("The phone will be asked for the PIN once.")}
          </p>

          <p :if={!@pin_set? and !@accounts?} id={"#{@id}-pin-hint"} class="note">
            <.badge tone="warn" icon="warning">{gettext("No PIN")}</.badge>
            {gettext(
              "Anybody on the hall's network who opens this address can renumber the boards. Set a PIN in Setup before the hall fills up."
            )} <.link navigate={~p"/setup/access"}>{gettext("Go to Setup")}</.link>
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
