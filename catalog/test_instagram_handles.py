"""Only an account the brand's own site links to becomes its Instagram
button; posts, reels and share widgets don't count."""
from instagram_handles import handles_in


def test_footer_account_wins_and_posts_are_ignored():
    page = '''<a href="https://www.instagram.com/kibonen/">IG</a>
      <a href="https://instagram.com/p/C9xYz12/">a post</a>
      <a href="https://www.instagram.com/reel/abc/">reel</a>
      <a href="https://instagram.com/kibonen?igsh=1">again</a>
      <a href="https://www.instagram.com/someone.else">credit</a>'''
    assert handles_in(page) == ["kibonen", "someone.else"]


def test_nothing_linked_means_nothing():
    assert handles_in('<a href="https://www.facebook.com/kibonen">fb</a>') == []
    assert handles_in('<script src="https://www.instagram.com/embed.js"></script>') == []
    assert handles_in('"https:\\/\\/www.instagram.com\\/kibonen_nyc"') == ["kibonen_nyc"]
    assert handles_in('src="https://www.instagram.com/v/t51.2885-15/abc.jpg"') == [], "a script path, not an account"


def test_a_site_builders_own_account_is_not_the_brands():
    page = 'href="https://www.instagram.com/threadbeauty/" "https:\\/\\/www.instagram.com\\/wix\\/" href="https://instagram.com/wix/"'
    assert handles_in(page) == ["threadbeauty"]


def test_handles_are_lowercased_and_trimmed():
    assert handles_in('href="https://instagram.com/Brown.Girl.Jane."') == ["brown.girl.jane"]
