defmodule Catalyst.Computer.StubBackend do
  @moduledoc """
  Test stub for `Catalyst.Tools.Computer.Backend`: returns canned data and
  reports every call to the pid registered via `record_to/1`
  (`{:computer_stub, call}` messages), so tool tests can assert exactly which
  backend ops ran with which arguments — no desktop, no TCC.

  Canned world: one main Retina display (1440×900 points @2x, origin {0, 0}),
  one window, cursor at {100, 50}. `capture/1` returns a tiny fake PNG payload
  with `scale: 2.0` and `ratio: 0.5`, so the coordinate round-trip
  (px ÷ ratio ÷ scale + origin) is exercised with non-trivial factors.
  """

  @behaviour Catalyst.Tools.Computer.Backend

  @pid_key {__MODULE__, :recorder}

  @doc "Register the test pid that receives `{:computer_stub, call}` messages."
  @spec record_to(pid()) :: :ok
  def record_to(pid) when is_pid(pid) do
    :persistent_term.put(@pid_key, pid)
    :ok
  end

  @doc "Stop recording (test cleanup)."
  @spec stop_recording() :: :ok
  def stop_recording do
    :persistent_term.erase(@pid_key)
    :ok
  end

  defp record(call) do
    case :persistent_term.get(@pid_key, nil) do
      pid when is_pid(pid) -> send(pid, {:computer_stub, call})
      nil -> :ok
    end

    :ok
  end

  @impl true
  def screens do
    record({:screens})

    {:ok,
     [
       %{
         id: 10,
         index: 0,
         main: true,
         bounds: %{x: 0, y: 0, width: 1440, height: 900},
         scale: 2.0
       }
     ]}
  end

  @impl true
  def windows do
    record({:windows})

    {:ok,
     [
       %{
         id: 42,
         pid: 999,
         app: "TestApp",
         title: "Test Document",
         layer: 0,
         bounds: %{x: 40, y: 60, width: 800, height: 600}
       }
     ]}
  end

  @impl true
  def cursor do
    record({:cursor})
    {:ok, %{x: 100, y: 50}}
  end

  @impl true
  def input(op) do
    record({:input, op})
    {:ok, %{"ok" => true}}
  end

  @impl true
  def capture(request) do
    record({:capture, request})

    {:ok,
     %{
       data: <<137, 80, 78, 71, 1, 2, 3>>,
       mime_type: "image/png",
       scale: 2.0,
       origin: {0, 0},
       ratio: 0.5,
       logical_size: {1440.0, 900.0},
       captured_size: {2880, 1800},
       bytes: 7
     }}
  end

  @impl true
  def grants do
    record({:grants})
    {:ok, %{accessibility: true, screen_recording: true}}
  end

  @impl true
  def capture_grant do
    record({:capture_grant})
    {:ok, true}
  end
end
