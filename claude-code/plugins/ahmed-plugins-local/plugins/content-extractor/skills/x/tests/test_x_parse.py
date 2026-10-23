# $X/tests/test_x_parse.py
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import x_parse as xp

def tw(tid, text="hi", user="alice", reply_to=None, conv="1", wrap=False, **extra):
    legacy = {"full_text": text, "created_at": "Fri Oct 09 13:35:53 +0000 2026", "lang": "en",
              "in_reply_to_status_id_str": reply_to, "conversation_id_str": conv,
              "reply_count": extra.pop("reply_count", 0), "retweet_count": 2, "favorite_count": 3,
              "quote_count": 0, "bookmark_count": 1, "entities": extra.pop("entities", {})}
    legacy.update(extra.pop("legacy", {}))
    t = {"__typename": "Tweet", "rest_id": tid, "legacy": legacy, "views": {"count": "100"},
         "core": {"user_results": {"result": {"__typename": "User", "rest_id": "u" + user,
                  "is_blue_verified": True, "core": {"screen_name": user, "name": user.title()},
                  "legacy": {"description": "bio"}}}}}
    t.update(extra)
    if wrap:
        return {"__typename": "TweetWithVisibilityResults", "tweet": {k: v for k, v in t.items() if k != "__typename"}}
    return t

def body(*tweets):
    return {"data": {"threaded_conversation_with_injections_v2": {"instructions": [
        {"type": "TimelineAddEntries", "entries": [
            {"entryId": f"tweet-{i}", "content": {"itemContent": {"tweet_results": {"result": t}}}}
            for i, t in enumerate(tweets)]}]}}}

class UrlTests(unittest.TestCase):
    def test_variants(self):
        for u in ["https://x.com/DevDsgn/status/2108552027962036228",
                  "https://twitter.com/DevDsgn/status/2108552027962036228?s=20",
                  "https://mobile.x.com/DevDsgn/status/2108552027962036228/photo/1",
                  "https://fxtwitter.com/DevDsgn/status/2108552027962036228",
                  "x.com/DevDsgn/status/2108552027962036228"]:
            self.assertEqual(xp.parse_status_url(u),
                             ("https://x.com/DevDsgn/status/2108552027962036228", "2108552027962036228", "DevDsgn"))
        self.assertEqual(xp.parse_status_url("https://x.com/i/web/status/42"), ("https://x.com/i/status/42", "42", None))

    def test_rejects_non_post(self):
        with self.assertRaises(ValueError):
            xp.parse_status_url("https://x.com/DevDsgn")

class WalkTests(unittest.TestCase):
    def test_finds_plain_wrapped_and_quoted_ignores_users_and_tombstones(self):
        quoted = tw("9", "quoted", user="bob", conv="9")
        main = tw("1", "main", quoted_status_result={"result": quoted}, legacy={"quoted_status_id_str": "9"})
        b = body(main, tw("2", "wrapped", reply_to="1", wrap=True), {"__typename": "TweetTombstone"})
        self.assertEqual([t["rest_id"] for t in xp.iter_tweet_results(b)], ["1", "9", "2"])

class NormalizeTests(unittest.TestCase):
    def test_text_entities_and_media_link(self):
        t = tw("1", "A &amp; B https://t.co/abc https://t.co/med",
               entities={"urls": [{"url": "https://t.co/abc", "expanded_url": "https://uiarc.dev"}]},
               legacy={"extended_entities": {"media": [{"type": "photo", "url": "https://t.co/med",
                       "media_url_https": "https://pbs.twimg.com/media/X.jpg", "ext_alt_text": "alt"}]}})
        n = xp.normalize(t)
        self.assertEqual(n["text"], "A & B https://uiarc.dev")
        self.assertEqual(n["media"], [{"type": "photo", "url": "https://pbs.twimg.com/media/X.jpg?name=orig",
                                       "preview": None, "alt": "alt"}])
        self.assertEqual(n["author"], {"screen_name": "alice", "name": "Alice", "verified": True})
        self.assertEqual(n["stats"], {"replies": 0, "retweets": 2, "likes": 3, "quotes": 0, "bookmarks": 1, "views": 100})
        self.assertEqual(n["url"], "https://x.com/alice/status/1")

    def test_note_tweet_wins(self):
        t = tw("1", "tronqué…", note_tweet={"note_tweet_results": {"result": {
            "text": "texte long https://t.co/z", "entity_set": {"urls": [{"url": "https://t.co/z", "expanded_url": "https://z.dev"}]}}}})
        self.assertEqual(xp.normalize(t)["text"], "texte long https://z.dev")

    def test_video_best_mp4(self):
        t = tw("1", legacy={"extended_entities": {"media": [{"type": "video", "media_url_https": "https://pbs.twimg.com/p.jpg",
               "video_info": {"variants": [{"content_type": "application/x-mpegURL", "url": "m3u8"},
                                           {"content_type": "video/mp4", "bitrate": 256000, "url": "low.mp4"},
                                           {"content_type": "video/mp4", "bitrate": 2176000, "url": "high.mp4"}]}}]}})
        self.assertEqual(xp.normalize(t)["media"][0]["url"], "high.mp4")

    def test_poll_card_note_article(self):
        poll = tw("1", card={"legacy": {"name": "poll2choice_text_only", "binding_values": [
            {"key": "choice1_label", "value": {"string_value": "Oui"}}, {"key": "choice1_count", "value": {"string_value": "7"}},
            {"key": "choice2_label", "value": {"string_value": "Non"}}, {"key": "choice2_count", "value": {"string_value": "3"}},
            {"key": "counts_are_final", "value": {"boolean_value": True}}]}},
            birdwatch_pivot={"subtitle": {"text": "Contexte ajouté"}, "title": "Readers added context"},
            article={"article_results": {"result": {"title": "Titre", "preview_text": "Aperçu",
                     "content_state": {"blocks": [{"text": "Para 1"}, {"text": "Para 2"}]}}}})
        n = xp.normalize(poll)
        self.assertEqual(n["poll"], {"choices": [{"label": "Oui", "count": 7}, {"label": "Non", "count": 3}], "final": True})
        self.assertIsNone(n["card"])
        self.assertEqual(n["note"], "Contexte ajouté")
        self.assertEqual(n["article"], {"title": "Titre", "text": "Para 1\n\nPara 2"})
        link = tw("2", card={"legacy": {"name": "summary_large_image", "url": "https://t.co/c", "binding_values": [
            {"key": "title", "value": {"string_value": "Arc UI"}}, {"key": "vanity_url", "value": {"string_value": "uiarc.dev"}}]}})
        self.assertEqual(xp.normalize(link)["card"], {"title": "Arc UI", "description": None, "url": "https://t.co/c", "domain": "uiarc.dev"})

class ThreadTests(unittest.TestCase):
    def test_collect_dedup_and_tree(self):
        b1 = body(tw("0", user="op"), tw("1", user="op", reply_to="0"), tw("2", user="op", reply_to="1"),
                  tw("3", user="bob", reply_to="1"), tw("4", user="cat", reply_to="3"))
        b2 = body(tw("3", user="bob", reply_to="1"), tw("5", user="dan", reply_to="77"), tw("9", user="eve", conv="9"))
        tweets = xp.collect([b1, b2])
        self.assertEqual(list(tweets), ["0", "1", "2", "3", "4", "5", "9"])
        th = xp.build_thread(tweets, "1")
        self.assertEqual(th["ancestors"], ["0"])
        self.assertEqual(th["children"]["1"], ["2", "3"])
        self.assertEqual(th["descendants"], {"2", "3", "4"})
        self.assertEqual(th["self_thread"], ["2"])
        self.assertEqual(th["orphans"], ["5"])

if __name__ == "__main__":
    unittest.main()
