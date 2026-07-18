defmodule CatalystWeb.ShellLive.RunDiagnosticsTest do
  use CatalystWeb.ConnCase, async: false

  alias Catalyst.Model
  alias Catalyst.Session.Manager
  alias CatalystWeb.ShellLive.RunDiagnostics

  test "starting a preview cancels and demonitors the previous preview task" do
    id = "diagnostics-preview-#{System.unique_integer([:positive, :monotonic])}"
    tmp = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(tmp)

    {:ok, %{pid: session}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: %Model{id: "faux", api: "faux"},
        tools: []
      )

    on_exit(fn ->
      resume(session)
      Manager.stop(id)
      File.rm_rf!(tmp)
    end)

    :ok = :sys.suspend(session)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        session_pid: session,
        prompt_preview: nil,
        prompt_preview_ref: nil,
        prompt_preview_pid: nil
      }
    }

    first = RunDiagnostics.preview(socket)
    first_pid = first.assigns.prompt_preview_pid
    first_monitor = Process.monitor(first_pid)

    second = RunDiagnostics.preview(first)

    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, :killed}, 1_000
    refute second.assigns.prompt_preview_pid == first_pid

    second_pid = second.assigns.prompt_preview_pid
    second_monitor = Process.monitor(second_pid)
    detached = %{second | assigns: Map.put(second.assigns, :session_pid, nil)}
    cleared = RunDiagnostics.preview(detached)

    assert_receive {:DOWN, ^second_monitor, :process, ^second_pid, :killed}, 1_000
    assert cleared.assigns.prompt_preview == nil
    assert cleared.assigns.prompt_preview_ref == nil
    assert cleared.assigns.prompt_preview_pid == nil
  end

  defp resume(pid) do
    case Process.info(pid, :status) do
      {:status, :suspended} -> :sys.resume(pid)
      _not_suspended -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
