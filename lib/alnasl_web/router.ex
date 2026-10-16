defmodule AlnaslWeb.Router do
  use AlnaslWeb, :router

  import AlnaslWeb.Hall, only: [gate: 2, put_locale: 2]
  import AlnaslWeb.UserAuth, only: [fetch_current_scope: 2]

  # Every page of the site. Who may be here is `AlnaslWeb.Hall.gate/2`'s:
  # on a box without accounts, where the request comes from and the PIN;
  # once there is an account (and always on the server), signed in or not.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlnaslWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
    plug :fetch_current_scope
    plug :gate
  end

  # The pages before the site: signing in, 02cloud, an invitation, the
  # sign-in link of a QR code, the account's password. Not behind the gate,
  # or nobody could get past it; each says itself whom it serves.
  pipeline :door do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlnaslWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
    plug :fetch_current_scope
  end

  scope "/", AlnaslWeb do
    pipe_through :door

    get "/log-in", SessionController, :new
    post "/log-in", SessionController, :create
    delete "/log-out", SessionController, :delete
    get "/log-in/qr/:token", SessionController, :qr

    get "/auth/keycloak", KeycloakAuthController, :new
    get "/auth/keycloak/callback", KeycloakAuthController, :callback

    get "/invite/:token", InvitationController, :show
    post "/invite/:token", InvitationController, :accept

    post "/accounts/first", AccountController, :first
    get "/account", AccountController, :show
    put "/account/password", AccountController, :update_password
  end

  # A join link opened in a browser: a page that says what it is for. Not
  # behind the PIN - the link is shown so that a bridge can reach it from
  # elsewhere, and the page holds nothing a code does not already give.
  pipeline :join_page do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {AlnaslWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug :put_locale
  end

  scope "/join", AlnaslWeb do
    pipe_through :join_page
    get "/:code", JoinController, :show
  end

  # The bridge redeeming a code (`Alnasl.Bridges.redeem/2`). JSON from a
  # program, not a form from a browser: no session, no CSRF token, no PIN.
  # The code is the credential, good once and for fifteen minutes.
  scope "/join", AlnaslWeb do
    post "/:code", JoinController, :redeem
  end

  # Installed theme packs' stylesheets and fonts (`Alnasl.ThemePacks`). No
  # pipeline and no PIN: the PIN page wears the theme as well, and the
  # controller answers 404 to everything that is not a file of an accepted
  # pack.
  scope "/themes", AlnaslWeb do
    get "/:id/theme.css", ThemePackController, :css
    get "/:id/fonts/:file", ThemePackController, :font
  end

  scope "/", AlnaslWeb do
    pipe_through :browser

    get "/unlock", DoorController, :unlock
    post "/unlock", DoorController, :enter
    get "/lock", DoorController, :lock
    get "/locale/:locale", DoorController, :locale

    get "/files/round/:round", FileController, :round
    get "/files/round/:round/board/:board", FileController, :game
    get "/files/t/:tid/round/:round", FileController, :round
    get "/files/t/:tid/round/:round/board/:board", FileController, :game
    get "/files/capture/:board/:name", FileController, :capture
    get "/files/labels", LabelsController, :index
    get "/halls/:id/enter", HallController, :enter

    # Every page of the site. One session, so moving between them keeps the
    # socket; the hook puts the language, the box's name and the connection
    # badge on each, and turns away a browser that has not given the PIN.
    live_session :hall, on_mount: AlnaslWeb.Hall do
      live "/", RoundLive, :index
      live "/round/:round", RoundLive, :index
      live "/round/:round/board/:board", GameLive, :show
      # The same pages for a tournament other than the box's own.
      live "/t/:tid", RoundLive, :index
      live "/t/:tid/round/:round", RoundLive, :index
      live "/t/:tid/round/:round/board/:board", GameLive, :show
      live "/boards", BoardsLive, :index
      live "/boards/number", WalkLive, :number
      live "/boards/find", WalkLive, :find
      live "/outbox", OutboxLive, :index
      live "/pgn", PgnLive, :index
      live "/recordings", RecordingsLive, :index
      live "/log", LogLive, :index
      live "/setup", SetupLive, :index
      live "/halls", HallsLive, :index
      live "/halls/:id", HallsLive, :show
      live "/help", HelpLive, :index
      live "/help/:chapter", HelpLive, :chapter
    end
  end
end
