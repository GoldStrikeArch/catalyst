defmodule CatalystWeb.FolderPickerTest do
  # async: false — swaps the :folder_picker application env.
  use ExUnit.Case, async: false

  alias CatalystWeb.FolderPicker

  setup do
    previous = Application.get_env(:catalyst_web, :folder_picker, :not_set)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  test "browser mode: nothing registered means no native picker" do
    Application.delete_env(:catalyst_web, :folder_picker)

    refute FolderPicker.available?()
    assert {:error, :no_native_picker} = FolderPicker.pick("/tmp")
  end

  test "a registered picker receives the starting directory and its result is normalized" do
    parent = self()

    Application.put_env(:catalyst_web, :folder_picker, fn start ->
      send(parent, {:picked_from, start})
      {:ok, "/projects/demo"}
    end)

    assert FolderPicker.available?()
    assert {:ok, "/projects/demo"} = FolderPicker.pick("/home/me")
    assert_received {:picked_from, "/home/me"}
  end

  test "cancel, errors, and malformed results are all tagged" do
    Application.put_env(:catalyst_web, :folder_picker, fn _start -> :cancelled end)
    assert :cancelled = FolderPicker.pick("/tmp")

    Application.put_env(:catalyst_web, :folder_picker, fn _start -> {:error, :no_display} end)
    assert {:error, :no_display} = FolderPicker.pick("/tmp")

    Application.put_env(:catalyst_web, :folder_picker, fn _start -> "/unwrapped" end)
    assert {:error, {:invalid_picker_result, "/unwrapped"}} = FolderPicker.pick("/tmp")

    Application.put_env(:catalyst_web, :folder_picker, fn _start -> {:ok, ""} end)
    assert {:error, {:invalid_picker_result, {:ok, ""}}} = FolderPicker.pick("/tmp")
  end

  defp restore(:not_set), do: Application.delete_env(:catalyst_web, :folder_picker)
  defp restore(value), do: Application.put_env(:catalyst_web, :folder_picker, value)
end
