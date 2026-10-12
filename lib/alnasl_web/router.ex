defmodule AlnaslWeb.Router do
  use AlnaslWeb, :router

  import AlnaslWeb.Hall, only: [gate: 2, put_locale: 2]

  # One pipeline. There are no accounts on the box: who may be here is
  # decided by where the request comes from and the PIN (`AlnaslWeb.Hall`).
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlnaslWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
    plug :gate
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
      live "/help", HelpLive, :index
    end
  end
end
