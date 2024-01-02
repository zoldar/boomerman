defmodule BoomermanWeb.PageController do
  use BoomermanWeb, :controller

  def game(conn, _params) do
    redirect(conn, to: "/game.html")
  end
end
