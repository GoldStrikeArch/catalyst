defmodule Catalyst.Test.BlockingExtensionChild do
  @moduledoc false

  def start_link({test, token}) do
    send(test, {:blocking_extension_child, self(), token})

    receive do
      {:release_blocking_extension_child, ^token} -> {:error, :released}
    end
  end
end
