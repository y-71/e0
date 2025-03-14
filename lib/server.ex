defmodule Server do
  use GenServer

  # Start the GenServer
  def start_link() do
    rss_url = "https://archive.org/services/collection-rss.php?collection=ucberkeley-webcast"
    saved_urls_path = "ucberkeley-webcast.json"
    saved_urls = get_saved_urls(saved_urls_path)
    saved_urls_hash = hash(saved_urls)
    initial_state = %{
                      rss_url: rss_url,
                      saved_urls_path: saved_urls_path,
                      saved_urls: saved_urls,
                      saved_urls_hash: saved_urls_hash
                    }
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  # GenServer Callbacks
  def init(state) do
    HTTPoison.start
    {:ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def get_rss_string(url) do
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, body}
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, "404 Not Found"}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  def fetch_latest_videos()do
    state = get_state()
    rss_url = state.rss_url
    saved_urls_hash = state.saved_urls_hash
    saved_urls_path = state.saved_urls_path

    with {:ok, rss_string} <- get_rss_string(rss_url),
        {:ok, map_of_rss} <- FastRSS.parse_rss(rss_string) do
          items = map_of_rss["items"]
          # for now, let's just flat map everything
          contents = Enum.map(items, fn(item) -> item["extensions"]["media"]["content"]end)|> List.flatten()
          urls = Enum.map(contents, fn(content) -> content["attrs"]["url"]end)

          urls_hash = :crypto.hash(:sha256, Enum.join(urls, ","))
                  |> Base.encode16()

          if saved_urls_hash == urls_hash do
            File.write(saved_urls_path, Poison.encode!(urls))
          end
          {:ok, urls}
          else
            {:error, reason} ->
              IO.puts("Error fetching or parsing RSS: #{inspect(reason)}")
              {:error, reason}
          end
  end

  defp download(url, filepath \\ "buffer.mp4")do
    if File.exists?(filepath) do
      File.rm(filepath)
    end
    # Start the download and handle the result
    {_, exit_status} = System.cmd("aria2c", ["-x", "16", "-s", "16", "-o", filepath, url], into: IO.stream(:stdio, :line))

    # Check if the command was successful
    if exit_status == 0 do
      {:ok, filepath}
    else
      {:error, exit_status}
    end
  end

  def download_next_video() do
    {:ok, urls} = fetch_latest_videos()
    url = hd urls
    download(url)
  end

  def convert_to_hls(input_path \\ "buffer.mp4", output_dir \\ ".") do
    output_m3u8 = Path.join(output_dir, "playlist.m3u8")

    File.mkdir_p!(output_dir)  # Ensure the output directory exists

    ffmpeg_command = [
      "-i", input_path,                # Input file
      "-codec:", "copy",               # Copy codec (no re-encoding)
      "-start_number", "0",            # Start segment numbering at 0
      "-hls_time", "10",               # 10s per segment
      "-hls_list_size", "0",           # Keep all segments
      "-hls_segment_filename",
      "#{output_dir}/segment_%03d.ts", # Segment pattern
      output_m3u8                      # Output playlist
    ]

    case System.cmd("ffmpeg", ffmpeg_command, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, error}
    end
  end

  def get_saved_urls(saved_urls_path) do
    case File.read(saved_urls_path) do
      {:ok, urls} ->  Poison.decode!(urls)
      {:error, _} -> []
    end
  end

  defp hash(list) do
    :crypto.hash(:sha256, Enum.join(list, ","))
      |> Base.encode16()
  end

  # Client API
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

end
