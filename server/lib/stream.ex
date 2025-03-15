defmodule HLSServer.Stream do
  use GenServer

  @stream_path "data/hls/"
  @playlist_file @stream_path <> "stream.m3u8"
  @target_duration 10
  @max_segments 5
  @update_interval :timer.seconds(@target_duration)

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def add_segment(segment_name) do
    IO.puts("..add_segment #{segment_name}")
    GenServer.cast(__MODULE__, {:add_segment, segment_name})
  end

  def get_stream, do: File.read!(@playlist_file)


  def init(_) do
    stream = load_stream()
    schedule_update()
    {:ok, stream}
  end

  def handle_info(:update, stream) do
    {:ok, updated_stream} = update_stream(stream)
    schedule_update()
    {:noreply, updated_stream}
  end

  def target_duration, do: @target_duration

  defp schedule_update() do
    IO.puts("schedule update")
    Process.send_after(self(), :update, @update_interval)
  end

  defp update_stream([type, version, target_duration, media_sequence, _inf2pop, _segment2pop | segments]) do
    IO.puts("..writing stream")
    [inf_1, seg_1| _tail] = segments
    IO.puts([type, version, target_duration, media_sequence, inf_1, seg_1])

    stream = [type, version, target_duration, media_sequence | segments]

    File.write!(@playlist_file, Enum.join(stream, "\n"))
    {:ok, stream}
  end

  defp load_stream() do
    case File.read(@playlist_file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        _ ->[]
    end
  end
end
