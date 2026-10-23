# $X/tests/test_x_post.py
import sys, unittest
from unittest import mock
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import x_post

FX = {"tweet": {"id": "1", "url": "https://x.com/op/status/1", "text": "Bonjour https://uiarc.dev",
      "author": {"screen_name": "op", "name": "Op", "verification": {"verified": True}},
      "created_at": "Fri Oct 09 13:35:53 +0000 2026", "lang": "fr", "replying_to_status": None,
      "likes": 3, "retweets": 2, "replies": 13, "views": 100, "quotes": None, "bookmarks": None,
      "media": {"all": [{"type": "photo", "url": "https://pbs.twimg.com/media/A.jpg?name=orig", "altText": "alt"},
                        {"type": "video", "url": "https://video.twimg.com/v.mp4", "thumbnail_url": "https://p/t.jpg"}]},
      "poll": {"choices": [{"label": "Oui", "count": 7}], "ends_at": "x", "time_left_en": "Final results"},
      "community_note": {"text": "Contexte"},
      "quote": {"id": "9", "url": "https://x.com/eve/status/9", "text": "cité", "author": {"screen_name": "eve", "name": "Eve"},
                "created_at": "Fri Oct 09 13:35:53 +0000 2026", "likes": 1, "retweets": 0, "replies": 0, "views": 5}}}

class FxTests(unittest.TestCase):
    def test_from_fxtwitter(self):
        main, quoted = x_post.from_fxtwitter(FX)
        self.assertEqual((main["id"], main["quoted_id"], main["source"]), ("1", "9", "fxtwitter"))
        self.assertEqual(main["author"], {"screen_name": "op", "name": "Op", "verified": True})
        self.assertEqual(main["stats"]["replies"], 13)
        self.assertEqual([m["type"] for m in main["media"]], ["photo", "video"])
        self.assertEqual(main["media"][1]["preview"], "https://p/t.jpg")
        self.assertEqual(main["poll"]["choices"], [{"label": "Oui", "count": 7}])
        self.assertEqual(main["note"], "Contexte")
        self.assertEqual(quoted["text"], "cité")

class RelevantTests(unittest.TestCase):
    def test_excludes_recommendations(self):
        import x_parse
        def tw(i, rt=None, q=None, conv="1"):
            return {"id": i, "reply_to": rt, "quoted_id": q, "conversation_id": conv,
                    "author": {"screen_name": "op"}}
        tweets = {x["id"]: x for x in [tw("1"), tw("2", "1", q="9"), tw("9", conv="9"), tw("8", conv="8")]}
        ids = x_post.relevant_ids(tweets, x_parse.build_thread(tweets, "1"))
        self.assertEqual(ids, ["1", "2", "9"])

class FallbackTests(unittest.TestCase):
    def test_no_cookies_uses_fxtwitter_and_says_so(self):
        calls = {}
        def fx(user, tid):
            calls.setdefault("fx", (user, tid))
            return FX
        p = [mock.patch.object(x_post, "load_cookies", lambda: None),
             mock.patch.object(x_post, "fetch_fxtwitter", fx),
             mock.patch.object(x_post, "capture", lambda *a, **k: self.fail("capture ne doit pas être appelée sans cookies"))]
        for m in p:
            m.start()
            self.addCleanup(m.stop)
        import tempfile, io, contextlib
        out = tempfile.mkdtemp()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = x_post.main(["https://x.com/op/status/1", "--outdir", out, "--no-media"])
        self.assertEqual(rc, 0)
        self.assertEqual(calls["fx"], ("op", "1"))
        self.assertIn("x_login.py", buf.getvalue())
        self.assertTrue((Path(out) / "x_1" / "post.md").exists())
        self.assertTrue((Path(out) / "x_1" / "tweets.json").exists())

class CliFlagTests(unittest.TestCase):
    def _run(self, *flags):
        import tempfile, io, contextlib
        p = [mock.patch.object(x_post, "load_cookies", lambda: None),
             mock.patch.object(x_post, "fetch_fxtwitter", lambda u, t: FX),
             mock.patch.object(x_post, "capture", lambda *a, **k: self.fail("pas de capture sans cookies"))]
        for m in p:
            m.start()
            self.addCleanup(m.stop)
        out = tempfile.mkdtemp()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = x_post.main(["https://x.com/op/status/1", "--outdir", out, "--no-media", *flags])
        return rc, Path(out) / "x_1", buf.getvalue()

    def test_quick_falls_back_to_fxtwitter(self):
        rc, d, text = self._run("--quick")
        self.assertEqual(rc, 0)
        self.assertTrue((d / "post.md").exists())
        self.assertIn("x_login.py", text)

    def test_replies_no_deep_writes_replies_md(self):
        rc, d, _ = self._run("--replies", "--no-deep", "--ranking", "Likes")
        self.assertEqual(rc, 0)
        self.assertTrue((d / "replies.md").exists())
        self.assertIn("Meilleures réponses", (d / "post.md").read_text(encoding="utf-8"))

    def test_flags_parse(self):
        with self.assertRaises(SystemExit):
            self._run("--ranking", "Nope")


if __name__ == "__main__":
    unittest.main()
