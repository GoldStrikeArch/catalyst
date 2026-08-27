defmodule CatalystDesktop.FolderPicker do
  @moduledoc """
  Native "choose a project folder" dialog for the desktop shell (wxWidgets).

  `CatalystDesktop.Application` registers `pick/1` as
  `config :catalyst_web, :folder_picker` when the native window is enabled, so
  the sidebar's **+** opens a `wxDirDialog` parented to the Catalyst window.

  `pick/1` blocks the calling process until the dialog closes (the shell calls
  it from a LiveView async task) and always destroys the dialog afterwards.
  Returns `{:ok, path}` | `:cancelled` | `{:error, reason}`.
  """

  import Bitwise

  # wx.hrl constants: wxID_OK, and wxDD_DEFAULT_STYLE
  # (wxCAPTION | wxSYSTEM_MENU | wxCLOSE_BOX | wxRESIZE_BORDER) | wxDD_DIR_MUST_EXIST.
  @wx_id_ok 5100
  @style 536_870_912 ||| 2048 ||| 4096 ||| 64 ||| 512

  @doc "Open the folder dialog at `default_path` and wait for the user's choice."
  @spec pick(String.t()) :: CatalystWeb.FolderPicker.result()
  def pick(default_path) when is_binary(default_path) do
    Desktop.Env.wx_use_env()

    dialog =
      :wxDirDialog.new(parent(),
        title: ~c"Choose a project folder",
        defaultPath: String.to_charlist(default_path),
        style: @style
      )

    try do
      choice(dialog, :wxDialog.showModal(dialog))
    after
      :wxDirDialog.destroy(dialog)
    end
  end

  defp choice(dialog, @wx_id_ok), do: {:ok, dialog |> :wxDirDialog.getPath() |> List.to_string()}
  defp choice(_dialog, _other_button), do: :cancelled

  # Parent the sheet to the app window when it is up; wx accepts a null parent.
  defp parent do
    case Process.whereis(CatalystDesktop.Application.window_id()) do
      nil -> :wx.null()
      pid -> Desktop.Window.frame(pid)
    end
  end
end
