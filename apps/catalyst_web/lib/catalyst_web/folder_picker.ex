defmodule CatalystWeb.FolderPicker do
  @moduledoc """
  Native "choose a project folder" dialog, injected by the shell that owns a window.

  A browser never reveals an absolute path, so the web app cannot open an OS
  folder picker itself. A shell with a native window registers one under
  `config :catalyst_web, :folder_picker` — a 1-arity function that receives the
  directory to start in and returns `t:result/0`. `CatalystDesktop` registers a
  wxWidgets `wxDirDialog` at boot; in plain browser mode nothing is registered,
  `available?/0` is false, and the sidebar falls back to an inline path form.

  `pick/1` blocks for as long as the dialog is open: call it from a task
  (`Phoenix.LiveView.start_async/3`), never from the LiveView process itself.
  """

  @typedoc "Outcome of one dialog run."
  @type result :: {:ok, String.t()} | :cancelled | {:error, term()}

  @doc "Whether the running shell registered a native picker."
  @spec available?() :: boolean()
  def available?, do: is_function(picker(), 1)

  @doc "Open the registered dialog starting at `default_path` (blocking)."
  @spec pick(String.t()) :: result()
  def pick(default_path) when is_binary(default_path) do
    case picker() do
      fun when is_function(fun, 1) -> normalize(fun.(default_path))
      _none -> {:error, :no_native_picker}
    end
  end

  defp picker, do: Application.get_env(:catalyst_web, :folder_picker)

  defp normalize({:ok, path}) when is_binary(path) and path != "", do: {:ok, path}
  defp normalize(:cancelled), do: :cancelled
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:invalid_picker_result, other}}
end
