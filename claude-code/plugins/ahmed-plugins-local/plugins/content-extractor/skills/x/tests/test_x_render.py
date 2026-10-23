# $X/tests/test_x_render.py
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import x_render, x_parse

def t(tid, user="op", reply_to=None, text=None, **kw):
    base = {"id": tid, "url": f"https://x.com/{user}/status/{tid}",
            "author": {"screen_name": user, "name": user.title(), "verified": False},
            "created_at": "Fri Oct 09 13:35:53 +0000 2026", "text": text or f"texte {tid}", "lang": "fr",
            "reply_to": reply_to, "conversation_id": "1", "quoted_id": None,
            "stats": {"replies": 1, "retweets": 2, "likes": 3, "quotes": 0, "bookmarks": 0, "views": 10},
            "media": [], "card": None, "poll": None, "note": None, "article": None, "source": "graphql"}
    base.update(kw)
    return base

class RenderTests(unittest.TestCase):
    def test_sections_and_indentation(self):
        tweets = {x["id"]: x for x in [
            t("0"), t("1", reply_to="0", quoted_id="9", media=[{"type": "photo", "url": "https://p/1.jpg?name=orig", "preview": None, "alt": "un chat"}],
              poll={"choices": [{"label": "Oui", "count": 7}], "final": True}, note="Contexte"),
            t("2", reply_to="1"), t("3", user="bob", reply_to="1"), t("4", user="cat", reply_to="3"),
            t("5", user="dan", reply_to="77"), t("9", user="eve", conversation_id="9")]}
        md = x_render.render_markdown(tweets, x_parse.build_thread(tweets, "1"))
        for needle in ["# Post de @op", "2026-10-09 13:35 UTC", "## Contexte (posts parents)", "texte 0",
                       "## Post cité", "@eve", "[photo] https://p/1.jpg?name=orig (alt : un chat)",
                       "Oui : 7", "Community Note : Contexte", "## Thread de l'auteur", "texte 2",
                       "## Meilleures réponses (top 20"]:
            self.assertIn(needle, md)
        self.assertNotIn("texte 4", md)  # sous-réponses seulement dans replies.md
        rmd = x_render.render_replies(tweets, x_parse.build_thread(tweets, "1"), "complet")
        for needle in ["complet", "## Réponses dont le parent n'a pas été récupéré", "texte 5", "texte 3"]:
            self.assertIn(needle, rmd)
        self.assertIn("\n  > texte 4", rmd)  # sous-réponse indentée sous @bob
        self.assertLess(rmd.index("@bob"), rmd.index("@cat"))

    def test_top_and_replies_ordering(self):
        def st(l, v=0):
            return {"replies": 0, "retweets": 0, "likes": l, "quotes": 0, "bookmarks": 0, "views": v}
        tw = [t("1")] + [t(f"r{k}", user=f"u{k}", reply_to="1", stats=st(k)) for k in range(25)]
        tw += [t("tie", user="tie", reply_to="1", stats=st(10, 999)),
               t("sub_a", user="sa", reply_to="r3", stats=st(0)), t("sub_b", user="sb", reply_to="r3", stats=st(99)),
               t("subsub", user="ss", reply_to="sub_a", stats=st(5))]
        tweets = {x["id"]: x for x in tw}
        th = x_parse.build_thread(tweets, "1")
        top = x_render.top_replies(tweets, th, 20)
        self.assertEqual(len(top), 20)
        self.assertEqual(top[:3], ["r24", "r23", "r22"])
        self.assertLess(top.index("tie"), top.index("r10"))
        rmd = x_render.render_replies(tweets, th, "h")
        self.assertLess(rmd.index("texte r24"), rmd.index("texte r3\n"))
        self.assertLess(rmd.index("texte sub_a"), rmd.index("texte sub_b"))
        self.assertIn("\n  > texte sub_a", rmd)
        self.assertIn("\n    > texte subsub", rmd)

if __name__ == "__main__":
    unittest.main()
