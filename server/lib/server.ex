defmodule HLSServer.Plug do
  use Plug.Router

  plug :add_cors_headers
  plug :match
  plug :dispatch

  options _ do
    send_resp(conn, 204, "")
  end

  get "/playlist.m3u8" do
    IO.puts("..serving dem playlist boiii")
    conn
    |> put_resp_content_type("application/vnd.apple.mpegurl")
    |> send_resp(200, HLSServer.Stream.get_stream())
  end

  get "/:file" do
    file_path = Path.join("data/hls", file)

    if File.exists?(file_path) do
      conn
      |> send_file(200, file_path)
    else
      send_resp(conn, 404, "File Not Found")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp add_cors_headers(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Content-Type")
  end
end


defmodule HLSServer.Application do
  use Application

  def start(_type, _args) do
    start()
  end
  def start() do
    port = 4000
    IO.puts("Server listening on port #{port}")

    children = [
      HLSServer.Stream,
      HLSServer.Scheduler,
      {Plug.Cowboy, scheme: :http, plug: HLSServer.Plug, options: [port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
