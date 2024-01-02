defmodule BoomermanWeb.Router do
  use BoomermanWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/", BoomermanWeb do
    get "/", PageController, :game
  end
end
