defmodule GymIntel.SourceBrowserTest do
  use ExUnit.Case, async: true
  alias GymIntel.SourceMonitor.{Browser, Content, Sources}

  test "rendered text passes through normalization without becoming executable HTML" do
    text =
      "CORE AED 199.00 per month + AED 89.00 joining fee PLUS AED 249.00 per month + AED 89.00 joining fee <script>literal text</script>"

    assert {:ok, html} =
             Browser.decode(Jason.encode!(%{ok: true, url: Sources.rendered_url(), text: text}))

    refute html =~ "<script>"
    source = Enum.find(Sources.all(), &(&1.id == "puregym_offer"))
    assert {:ok, parsed} = Content.extract(html, source)
    assert parsed.text =~ "199.00"
    assert parsed.text =~ "<script>literal text</script>"
  end

  test "wrong branch, oversized output and browser failures cannot become successful checks" do
    assert {:error, :unapproved_url} =
             Browser.fetch("https://puregym-arabia.exerp.site/join/plan?center=8001")

    assert {:error, :invalid_rendered_page} =
             Browser.decode(Jason.encode!(%{ok: true, url: "https://example.com", text: "CORE"}))

    assert {:error, :invalid_rendered_page} =
             Browser.decode(
               Jason.encode!(%{
                 ok: true,
                 url: Sources.rendered_url(),
                 text: String.duplicate("x", 100_001)
               })
             )

    assert {:error, {:browser, "browser_timeout"}} =
             Browser.decode(~s({"ok":false,"reason":"browser_timeout"}))

    assert {:error, :invalid_rendered_page} = Browser.decode("incomplete output")
  end
end
