import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from x_capture import cursor_labels, EXPAND, page_done, rewrite_ranking, ranking_passes  # noqa: E402


class CursorLabels(unittest.TestCase):
    def test_collects_non_edge_cursors(self):
        body = {"a": [{"content": {"cursorType": "ShowMore", "displayTreatment": {"actionText": "Voir les r\u00e9ponses"}}},
                      {"cursorType": "ShowMoreThreads", "displayTreatment": {"actionText": " Afficher les spams probables "}},
                      {"cursorType": "Bottom", "displayTreatment": {"actionText": "x"}},
                      {"cursorType": "Top"},
                      {"displayTreatment": {"actionText": "not a cursor"}}]}
        self.assertEqual(cursor_labels([body, {}]), {"Voir les r\u00e9ponses", "Afficher les spams probables"})

    def test_french_regex(self):
        self.assertTrue(EXPAND.match("Afficher les spams probables"))
        self.assertTrue(EXPAND.match("Voir les r\u00e9ponses"))
        self.assertFalse(EXPAND.match("Reply"))


def _td(*cursors):
    return {"op": "TweetDetail", "body": {"entries": [{"cursorType": c[0], "displayTreatment": {"actionText": c[1]}}
                                                      for c in cursors]}}


class PageDone(unittest.TestCase):
    def test_bottom_pending(self):
        self.assertFalse(page_done([_td(("Bottom", "x"))], set()))

    def test_no_bottom(self):
        self.assertTrue(page_done([_td(("Top", "x"))], set()))

    def test_only_last_detail_counts(self):
        self.assertTrue(page_done([_td(("Bottom", "x")), _td(("Top", "x"))], set()))

    def test_terminate_bottom_is_real_end(self):
        d = _td(("Bottom", "x"))
        d["body"]["instructions"] = [{"type": "TimelineTerminateTimeline", "direction": "Bottom"}]
        self.assertTrue(page_done([d], set()))
        d["body"]["instructions"] = [{"type": "TimelineTerminateTimeline", "direction": "Top"}]
        self.assertFalse(page_done([d], set()))

    def test_unclicked_label(self):
        p = [_td(("ShowMore", "Show replies"))]
        self.assertFalse(page_done(p, set()))
        self.assertTrue(page_done(p, {"Show replies"}))


class Passes(unittest.TestCase):
    def test_passes(self):
        self.assertEqual(ranking_passes(True, None), ["Likes"])
        self.assertEqual(ranking_passes(False, None), [None, "Likes", "Recency"])
        self.assertEqual(ranking_passes(False, "Recency"), ["Recency"])


class RewriteRanking(unittest.TestCase):
    def test_rewrites_only_tweetdetail(self):
        import json, urllib.parse
        u = ("https://x.com/i/api/graphql/abc/TweetDetail?variables="
             + urllib.parse.quote(json.dumps({"focalTweetId": "1", "rankingMode": "Relevance"})) + "&features=%7B%7D")
        new = rewrite_ranking(u, "Likes")
        q = urllib.parse.parse_qs(new.split("?", 1)[1])
        self.assertEqual(json.loads(q["variables"][0]), {"focalTweetId": "1", "rankingMode": "Likes"})
        self.assertEqual(q["features"], ["{}"])
        other = "https://x.com/i/api/graphql/abc/Other?variables=%7B%7D"
        self.assertEqual(rewrite_ranking(other, "Likes"), other)


if __name__ == "__main__":
    unittest.main()
