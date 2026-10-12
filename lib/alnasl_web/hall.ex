defmodule AlnaslWeb.Hall do
  @moduledoc """
  What every page of the site needs before it draws anything: the language,
  the box's name, the connection to the results server - kept current - and
  the answer to "may this browser be here at all".

  ## Who may be here

  The box itself always may: a request from the loopback address is the
  kiosk browser on the box. A browser on another machine in the hall may
  when no PIN is set, or once it has given the PIN (`/unlock`). The plug
  (`gate/2`) decides for ordinary requests and notes in the session how the
  browser came in; `on_mount/4` reads that note for the LiveView socket.
  """

  import Plug.Conn
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, redirect: 2]

  alias Alnasl.{Outbox, Settings}

  # --- the plug ----------------------------------------------------------------

  @doc "Puts the language in place for a controller request."
  def put_locale(conn, _opts) do
    Gettext.put_locale(AlnaslWeb.Gettext, locale())
    conn
  end

  @doc "Lets the box in, and anybody else once they have given the PIN."
  def gate(conn, _opts) do
    local? = loopback?(conn.remote_ip)
    conn = put_session(conn, :local, local?)

    if allowed?(local?, get_session(conn, :unlocked)) or conn.request_path == "/unlock" do
      conn
    else
      conn |> Phoenix.Controller.redirect(to: "/unlock") |> halt()
    end
  end

  defp allowed?(local?, unlocked), do: local? or unlocked == true or not Settings.pin_set?()

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, _}), do: true
  defp loopback?(_other), do: false

  defp locale do
    case Settings.get("locale") do
      locale when locale in ["en", "nl"] -> locale
      _other -> "en"
    end
  end

  # --- the LiveView hook -------------------------------------------------------

  def on_mount(:default, _params, session, socket) do
    locale = locale()
    Gettext.put_locale(AlnaslWeb.Gettext, locale)

    if allowed?(session["local"] == true, session["unlocked"]) do
      if connected?(socket) do
        Outbox.subscribe()
        Settings.subscribe()
      end

      socket =
        socket
        |> assign(
          link: Outbox.status(),
          box: Settings.get("box_name") || "Alnasl",
          locale: locale
        )
        |> attach_hook(:hall, :handle_info, &info/2)

      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/unlock")}
    end
  end

  # Keeps the connection badge and the box's name current on every page. The
  # message goes on to the page, which may care too.
  defp info(:outbox_changed, socket), do: {:cont, assign(socket, link: Outbox.status())}

  defp info({:setting, "box_name"}, socket) do
    {:cont, assign(socket, link: Outbox.status(), box: Settings.get("box_name") || "Alnasl")}
  end

  defp info(_other, socket), do: {:cont, socket}
end
