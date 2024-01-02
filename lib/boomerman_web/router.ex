defmodule BoomermanWeb.Router do
  use BoomermanWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", BoomermanWeb do
    pipe_through :api
  end
end
