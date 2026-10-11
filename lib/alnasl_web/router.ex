defmodule AlnaslWeb.Router do
  use AlnaslWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlnaslWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AlnaslWeb do
    pipe_through :browser

  end

  # Other scopes may use custom stacks.
  # scope "/api", AlnaslWeb do
  #   pipe_through :api
  # end
end
