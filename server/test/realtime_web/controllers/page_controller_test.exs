defmodule RealtimeWeb.PageControllerTest do
  use RealtimeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "tealbase Realtime"
  end
end
