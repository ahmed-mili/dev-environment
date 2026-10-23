#!/usr/bin/env python3
"""shop_sites.py — un parseur par site. Chaque fetch_<site>(br, url, opts) renvoie (product, reviews, qa)."""
import re
from urllib.parse import quote, quote_plus, urlparse

from shop_common import (Blocked, avail_text, clean, jsonld_product, jsonld_reviews,
                         num, parse_date, soup)


class NotProduct(Exception):
    pass


def detect(url):
    h = urlparse(url).netloc.lower()
    for key, site in (("amazon.", "amazon"), ("ldlc.", "ldlc"), ("cdiscount.", "cdiscount"), ("topachat.", "topachat")):
        if key in h:
            return site
    return None


def product_id(site, url):
    if site == "amazon":
        m = re.search(r"/(?:dp|gp/product|product-reviews)/([A-Z0-9]{10})", url)
    elif site == "ldlc":
        m = re.search(r"/(?:fiche|avis)/(PB\d+)", url)
    elif site == "cdiscount":
        m = re.search(r"/f-\d+-([a-z0-9]+)\.html", url)
    else:
        m = re.search(r"_ref_est_(in\d+)", url)
    return m.group(1) if m else None


def base_product(site, url, pid):
    return {"site": site, "id": pid, "url": url, "canonical": url, "title": None, "brand": None,
            "reference": None, "gtin": None, "price": None, "currency": "EUR", "price_text": None,
            "old_price": None, "availability": None, "delivery": None, "seller": None, "shipped_by": None,
            "rating": None, "rating_scale": 5, "review_count": None, "specs": [], "bullets": [],
            "description": None, "histogram": None, "notes": []}


def canonical(sp, url):
    e = sp.select_one("link[rel=canonical]")
    return e["href"] if e and e.get("href") else url


def first_offer(ld):
    off = ld.get("offers") or {}
    if isinstance(off, list):
        off = off[0] if off else {}
    return off


# ---------------------------------------------------------------- Amazon
def parse_amazon_reviews(sp, source):
    out, seen = [], set()
    for r in sp.select('[data-hook="review"]'):
        rid = r.get("id") or str(len(out))
        if rid in seen:
            continue
        seen.add(rid)

        def tx(*hooks):
            for h in hooks:
                e = r.select_one(f'[data-hook="{h}"]')
                if e:
                    return clean(e.get_text(" "))
            return ""
        stars = tx("review-star-rating", "cmps-review-star-rating")
        m = re.search(r"([\d,.]+)\s*(?:étoiles?)? sur 5", stars)
        title = r.select_one('[data-hook="review-title"], [data-hook="reviewTitle"]')
        spans = title.find_all("span") if title else []
        ttl = next((t for t in (clean(s.get_text(" ")) for s in reversed(spans)) if t), "") \
            or tx("review-title", "reviewTitle")
        body = (r.select_one('[data-hook="reviewRichContentContainer"]')
                or r.select_one('[data-hook="review-body"] span')
                or r.select_one('[data-hook="reviewText"]'))
        text = clean(body.get_text(" ")) if body else ""
        text = re.sub(r"^Brief content visible.*?Full content visible, double tap to read brief content\.\s*", "", text)
        hm = re.search(r"(\d+|Une)\s+personne", tx("helpful-vote-statement"))
        prof = r.select_one(".a-profile-name")
        out.append({
            "author": clean(prof.get_text(" ")) if prof else tx("genome-widget"),
            "rating": num(m.group(1)) if m else None, "scale": 5,
            "date": parse_date(tx("review-date")), "date_text": tx("review-date"),
            "title": ttl, "text": text, "verified": bool(r.select_one('[data-hook="avp-badge"]')),
            "helpful": (1 if hm.group(1) == "Une" else int(hm.group(1))) if hm else None,
            "source": source,
        })
    return out


def halve(t):
    """'YUTAO TECH YUTAO TECH Vendu par YUTAO TECH' -> 'YUTAO TECH' (Amazon double les libellés)."""
    w = t.split()
    for n in range(1, len(w) // 2 + 1):
        if w[:n] == w[n:2 * n]:
            return " ".join(w[:n])
    return t


def fetch_amazon(br, url, o):
    asin = product_id("amazon", url)
    if not asin:
        raise NotProduct("pas d'ASIN dans l'URL (attendu /dp/<ASIN>)")
    dp = f"https://www.amazon.fr/dp/{asin}"
    sp = soup(br.get(dp, scroll=True))
    if not sp.select_one("#productTitle"):
        raise NotProduct("pas de #productTitle sur la page")
    p = base_product("amazon", dp, asin)
    p["canonical"] = canonical(sp, dp)
    p["title"] = clean(sp.select_one("#productTitle").get_text())
    by = clean((sp.select_one("#bylineInfo") or sp.new_tag("x")).get_text(" "))
    p["brand"] = re.sub(r"^(Marque\s*:|Visiter la boutique\s*|Visiter la page\s*)\s*", "", by).strip() or None
    pr = (sp.select_one("#corePrice_feature_div .a-price:not(.a-text-price) .a-offscreen")
          or sp.select_one(".priceToPay .a-offscreen")
          or sp.select_one("#corePriceDisplay_desktop_feature_div .a-offscreen")
          or sp.select_one("#desktop_buybox .a-offscreen"))
    if pr:
        p["price_text"] = clean(pr.get_text())
        p["price"] = num(p["price_text"])
    old = sp.select_one("#corePrice_feature_div .a-text-price .a-offscreen, .basisPrice .a-offscreen")
    if old:
        p["old_price"] = num(old.get_text())
    av = sp.select_one("#availability")
    p["availability"] = clean(av.get_text(" ")) if av else None
    dl = sp.select_one("#deliveryBlockMessage, #mir-layout-DELIVERY_BLOCK")
    p["delivery"] = re.sub(r"\s*Détails\s*$", "", clean(dl.get_text(" "))) if dl else None
    ship = sold = None
    for row in sp.select("#tabular-buybox .tabular-buybox-container"):
        lab = clean((row.select_one(".tabular-buybox-label, .a-color-secondary") or row).get_text(" ")).lower()
        vals = row.select(".tabular-buybox-text")
        val = clean(vals[-1].get_text(" ")) if vals else ""
        if lab.startswith("expédié"):
            ship = val
        elif lab.startswith("vendu"):
            sold = val
    if not (ship or sold):
        mi = clean((sp.select_one("#merchantInfoFeature_feature_div") or sp.new_tag("x")).get_text(" "))
        mf = clean((sp.select_one("#fulfillerInfoFeature_feature_div") or sp.new_tag("x")).get_text(" "))
        m2 = re.search(r"Vendu par (.+)", mi)
        m3 = re.search(r"Expédié par (.+)", mf or mi)
        sold = halve(m2.group(1)) if m2 else (mi or None)
        ship = halve(m3.group(1)) if m3 else None
    p["seller"], p["shipped_by"] = sold, ship
    rt = sp.select_one("#acrPopover")
    if rt:
        p["rating"] = num(rt.get("title") or rt.get_text(" "))
    rc = sp.select_one("#acrCustomerReviewText")
    if rc:
        d = re.sub(r"\D", "", rc.get_text())
        p["review_count"] = int(d) if d else None
    hist = {}
    for tr in sp.select("#histogramTable tr, [data-hook=histogram-row]"):
        mm = re.search(r"(\d) étoiles?.*?(\d+)\s*%", clean(tr.get_text(" ")))
        if mm:
            hist[mm.group(1)] = int(mm.group(2))
    p["histogram"] = hist or None
    p["bullets"] = [clean(li.get_text(" ")) for li in sp.select("#feature-bullets li")]
    seen = set()

    def add(g, k, v):
        k, v = clean(k).strip(" :‎‏"), clean(v).strip("‎‏ ")
        if k and v and (k, v) not in seen:
            seen.add((k, v))
            p["specs"].append([g, k, v])
    for tr in sp.select("#productOverview_feature_div tr"):
        tds = tr.find_all(["td", "th"])
        if len(tds) >= 2:
            add("Aperçu", tds[0].get_text(" "), tds[1].get_text(" "))
    for t in sp.select("table.prodDetTable"):
        for tr in t.select("tr"):
            th, td = tr.find("th"), tr.find("td")
            if th and td:
                add("Détails techniques", th.get_text(" "), td.get_text(" "))
    for li in sp.select("#detailBullets_feature_div li"):
        b = li.select("span.a-text-bold")
        if b:
            k = b[0].get_text(" ")
            add("Détails", k, clean(li.get_text(" ")).replace(clean(k), "", 1))
    desc = sp.select_one("#productDescription")
    p["description"] = clean(desc.get_text(" ")) if desc else None

    reviews = [] if o.get("no_reviews") else parse_amazon_reviews(sp, "page produit (avis mis en avant, sans connexion)")
    qa = []
    if o.get("no_reviews"):
        pass
    elif br.cookies:
        try:
            more = amazon_logged_reviews(br, asin, o)
            keys = {(m["author"], m["title"]) for m in more}
            reviews = more + [r for r in reviews if (r["author"], r["title"]) not in keys]
            p["notes"].append(f"{len(more)} avis récupérés via /product-reviews/ avec la session Brave")
            try:
                qa = amazon_qa(br, asin)
            except Blocked as e:
                p["notes"].append(f"Q&A Amazon indisponible ({e}) ; les avis ci-dessus sont valides")
        except Blocked as e:
            p["notes"].append(f"session Amazon refusée ({e}) : relancer shop_login.py ; "
                              "repli = avis de la page produit seulement")
    else:
        p["notes"].append("pas de cookies Amazon : seulement les avis mis en avant de la page produit ; "
                          "avis complets et Q&A exigent une connexion (shop_login.py)")
    return p, reviews, qa


def amazon_logged_reviews(br, asin, o):
    out, seen = [], set()
    star = "critical" if o.get("negative") else "all_stars"
    sort = "recent" if (o.get("recent") or o.get("negative")) else "helpful"
    for n in range(1, o.get("pages", 3) + 1):
        u = (f"https://www.amazon.fr/product-reviews/{asin}/?reviewerType=all_reviews&filterByStar={star}"
             f"&sortBy={sort}&pageNumber={n}")
        got = parse_amazon_reviews(soup(br.get(u)), f"/product-reviews page {n}")
        # Amazon renvoie la dernière page quand pageNumber la dépasse : s'arrêter dès qu'aucun avis n'est nouveau.
        new = [r for r in got if (r["author"], r["date"], r["text"][:80]) not in seen]
        if not new:
            break
        seen.update((r["author"], r["date"], r["text"][:80]) for r in new)
        out += new
    return out


def amazon_qa(br, asin):
    out = []
    for n in range(1, 3):
        sp = soup(br.get(f"https://www.amazon.fr/ask/questions/asin/{asin}/{n}/"))
        qs = sp.select(".askTeaserQuestions > div, [id^=question-]")
        if not qs:
            break
        for q in qs:
            qt = q.select_one("a[href*=question], .a-link-normal")
            ans = [clean(a.get_text(" ")) for a in q.select(".askLiveSearchHide, .a-spacing-base span")]
            out.append({"question": clean(qt.get_text(" ")) if qt else clean(q.get_text(" "))[:200],
                        "answers": [a for a in ans if a][:3]})
    return out


# ---------------------------------------------------------------- LDLC
def fetch_ldlc(br, url, o):
    pid = product_id("ldlc", url)
    if not pid:
        raise NotProduct("URL LDLC attendue : /fiche/PBxxxxxxxx.html")
    u = f"https://www.ldlc.com/fiche/{pid}.html"
    sp = soup(br.get(u))
    ld = jsonld_product(sp)
    h1 = sp.select_one("h1")
    if not ld or not h1:
        raise NotProduct("pas de JSON-LD Product / h1")
    p = base_product("ldlc", u, pid)
    p["canonical"] = canonical(sp, u)
    p["title"] = clean(h1.get_text(" "))
    p["brand"] = (ld.get("brand") or {}).get("name")
    p["reference"], p["gtin"] = ld.get("mpn"), ld.get("gtin13")
    off = first_offer(ld)
    p["price"] = num(off.get("price"))
    pe = sp.select_one(".product-price .price, #product-page-price .price")
    p["price_text"] = clean(pe.get_text()) if pe else None
    ref = sp.select_one(".product-infoPrice .refPrice, .price-ref, .old-price, .product-price s")
    p["old_price"] = num(ref.get_text()) if ref else None
    stock = sp.select_one(".stock")
    p["availability"] = clean(stock.get_text(" ")) if stock else avail_text(off.get("availability"))
    for e in sp.select("[class*=delivery], [class*=livraison], .shipping"):
        t = clean(e.get_text(" "))
        if re.search(r"livr|retrait|expédi", t, re.I) and 15 < len(t) < 300:
            p["delivery"] = t
            break
    p["seller"] = (off.get("seller") or {}).get("name") or "LDLC"
    p["shipped_by"] = "LDLC"
    ar = ld.get("aggregateRating") or {}
    p["rating"] = num(ar.get("ratingValue"))
    p["review_count"] = int(num(ar.get("reviewCount")) or 0) or None
    p["rating_scale"] = num(ar.get("bestRating")) or 5
    p["description"] = clean(ld.get("description"))
    group = ""
    for tr in sp.select("#product-parameters tr"):
        t = tr.select_one("td.title")
        if t:
            group = clean(t.get_text(" "))
        lab = tr.select_one("td.label")
        tds = tr.select("td")
        if lab and len(tds) >= 2:
            lbl = tds[-1].select_one("label")
            v = clean(lbl.get_text(" ")) if lbl else clean(tds[-1].get_text(" "))
            p["specs"].append([group, clean(lab.get_text(" ")), v])
    reviews = []
    if not o.get("no_reviews"):
        reviews = parse_ldlc_reviews(soup(br.get(f"https://www.ldlc.com/avis/{pid}.html")))
        if not reviews:
            reviews = parse_ldlc_reviews(sp)
        p["notes"].append("notes LDLC données sur 10 (échelle conservée dans reviews.json, convertie sur 5 pour le tri)")
    return p, reviews, []


def parse_ldlc_reviews(sp):
    out = []
    for li in sp.select("ul.reviews > li"):
        au = li.select_one(".author strong")
        dates = [clean(d.get_text(" ")) for d in li.select(".author .date")]
        st = li.select_one(".content .ratingClient span[class^=star-]")
        sm = re.search(r"star-(\d+)", " ".join(st.get("class"))) if st else None
        ti = li.select_one(".content .title")
        body = li.select_one(".content > p")
        mod = li.select_one(".review--model")
        like = li.select_one("button.nb-like .nb")
        lk = like.get_text().strip() if like else ""
        out.append({
            "author": re.sub(r"^par\s+", "", clean(au.get_text())) if au else None,
            "rating": int(sm.group(1)) if sm else None, "scale": 10,
            "date": parse_date(dates[0]) if dates else None,
            "title": clean(ti.get_text()) if ti else "", "text": clean(body.get_text(" ")) if body else "",
            "verified": any("Acheté" in d for d in dates), "helpful": int(lk) if lk.isdigit() else None,
            "extra": clean(mod.get_text(" ")) if mod else None, "source": "LDLC /avis",
        })
    return out


# ---------------------------------------------------------------- Cdiscount
def fetch_cdiscount(br, url, o):
    pid = product_id("cdiscount", url)
    if not pid:
        raise NotProduct("URL Cdiscount attendue : .../f-<rayon>-<code>.html")
    u = url.split("#")[0].split("?")[0]
    sp = soup(br.get(u, scroll=True))
    ld = jsonld_product(sp)
    h1 = sp.select_one("h1")
    if not ld or not h1:
        raise NotProduct("pas de JSON-LD product / h1")
    p = base_product("cdiscount", u, pid)
    p["canonical"] = canonical(sp, u)
    p["title"] = clean(h1.get_text(" "))
    p["brand"] = (ld.get("brand") or {}).get("name")
    p["gtin"], p["reference"] = ld.get("gtin"), ld.get("sku")
    off = first_offer(ld)
    p["price"] = num(off.get("price"))
    p["price_text"] = f"{off.get('price')} €" if off.get("price") is not None else None
    p["availability"] = avail_text(off.get("availability"))
    ar = ld.get("aggregateRating") or {}
    p["rating"] = round(num(ar.get("ratingValue")), 2) if ar.get("ratingValue") else None
    p["review_count"] = int(num(ar.get("ratingCount") or ar.get("reviewCount")) or 0) or None
    p["description"] = clean(ld.get("description"))
    tables = []
    for tbl in sp.select("table"):
        rows = []
        for tr in tbl.select("tr"):
            c = [clean(x.get_text(" ")) for x in tr.find_all(["th", "td"])]
            if len(c) >= 2 and c[0] and c[1]:
                rows.append(c[:2])
        if rows:
            hd = tbl.find_previous(["h2", "h3", "h4"])
            tables.append((clean(hd.get_text(" ")) if hd else "", rows))
    for g, rows in tables:
        for k, v in rows:
            p["specs"].append([g, k, v])
    for t in sp(["script", "style", "noscript"]):
        t.decompose()
    txt = "\n".join(l for l in (clean(x) for x in sp.get_text("\n").split("\n")) if l and l != "‌")
    m = re.search(r"Vendu par\n(.+?)\net expédié par\n(.+?)\n", txt)
    if m:
        p["seller"], p["shipped_by"] = m.group(1), m.group(2)
    else:
        m = re.search(r"Vendu et expédié par\n(.+?)\n", txt)
        if m:
            p["seller"] = p["shipped_by"] = m.group(1)
    m = re.search(r"\nLivraison\n(.+?)\nFaites vous livrer", txt, re.S)
    if m:
        p["delivery"] = clean(m.group(1).replace("\n", " "))
        dm = re.search(r"\n(Chez vous dès|En point retrait dès)\n([^\n]+)", txt)
        if dm:
            p["delivery"] += f" | {dm.group(1)} {dm.group(2)}"
    m = re.search(r"Points forts\n((?:[^\n]+\n){1,8}?)Voir le descriptif", txt)
    if m:
        p["bullets"] = [l for l in m.group(1).split("\n") if l]
    reviews = [] if o.get("no_reviews") else jsonld_reviews(ld)
    for r in reviews:
        r["source"] = "JSON-LD de la fiche (échantillon)"
    qa = []
    m = re.search(r"Questions et réponses\n(\d+)\nquestion", txt)
    b = re.search(r"Question la plus utile\n(.*?)\nVoir toutes les questions", txt, re.S)
    if b:
        for seg in re.split(r"\nRépondre\n?", b.group(1)):
            q = re.search(r"^(.*?)\nQuestion posée\npar\n(.+?)\nle\s+(\S+)", seg, re.S)
            if not q:
                continue
            a = re.search(r"Signaler\n\d+\n(.*?)(?:\nVoir plus)?\nRéponse de\n(.+?)\nle\s+(\S+)", seg, re.S)
            qa.append({"question": clean(q.group(1)), "asked_by": q.group(2), "date": parse_date(q.group(3)),
                       "answers": [clean(a.group(1)) + f" (réponse de {a.group(2)}, {a.group(3)})"] if a else []})
    if m and m.group(1) != "0":
        p["notes"].append(f"{m.group(1)} question(s) sur la fiche, {len(qa)} extraite(s) (les plus utiles)")
    if p["review_count"] and len(reviews) < p["review_count"]:
        p["notes"].append(f"{len(reviews)} avis exposés sur {p['review_count']} : la fiche n'en embarque qu'un échantillon")
    return p, reviews, qa


# ---------------------------------------------------------------- TopAchat
def fetch_topachat(br, url, o):
    pid = product_id("topachat", url)
    if not pid:
        raise NotProduct("URL TopAchat attendue : /pages/detail2_..._ref_est_inXXXX.html")
    u = url.split("#")[0]
    sp = soup(br.get(u))
    ld = jsonld_product(sp)
    h1 = sp.select_one("h1")
    if not ld or not h1:
        raise NotProduct("pas de JSON-LD Product / h1 (URL tronquée ou redirigée vers l'accueil ?)")
    p = base_product("topachat", u, pid)
    p["canonical"] = canonical(sp, u)
    p["title"] = clean(h1.get_text(" "))
    p["brand"] = (ld.get("brand") or {}).get("name")
    p["reference"], p["gtin"] = ld.get("mpn"), ld.get("gtin13")
    off = first_offer(ld)
    p["price"] = num(off.get("price"))
    p["price_text"] = f"{off.get('price')} €" if off.get("price") is not None else None
    stock = None
    for t in sp.find_all(string=re.compile(r"^\s*(EN STOCK|STOCK LIMITÉ|RUPTURE|INDISPONIBLE|PRÉCOMMANDE|DISPONIBLE)", re.I)):
        stock = clean(t)
        break
    p["availability"] = stock or avail_text(off.get("availability"))
    p["seller"] = (off.get("seller") or {}).get("name") or "TopAchat"
    p["shipped_by"] = "TopAchat"
    ar = ld.get("aggregateRating") or {}
    p["rating"] = num(ar.get("ratingValue"))
    p["review_count"] = int(num(ar.get("reviewCount")) or 0) or None
    p["description"] = clean(ld.get("description"))
    for g in sp.select(".ps-preview-spec__group"):
        h = g.find("h3")
        gname = clean(h.get_text(" ")) if h else ""
        for row in g.select(".ps-preview-spec__row"):
            dt, dd = row.find("dt"), row.find("dd")
            if dt and dd:
                item = [gname, clean(dt.get_text(" ")), clean(dd.get_text(" "))]
                if item not in p["specs"]:
                    p["specs"].append(item)
    reviews = [] if o.get("no_reviews") else jsonld_reviews(ld)
    for r in reviews:
        r["source"] = "JSON-LD de la fiche TopAchat"
    return p, reviews, []


FETCHERS = {"amazon": fetch_amazon, "ldlc": fetch_ldlc, "cdiscount": fetch_cdiscount, "topachat": fetch_topachat}


# ---------------------------------------------------------------- recherche
def search(br, site, query, limit=15):
    q = query.strip()
    res = []
    if site == "ldlc":
        sp = soup(br.get(f"https://www.ldlc.com/recherche/{quote(q)}/"))
        for li in sp.select("li.pdt-item"):
            a = li.select_one("h3 a[href*='/fiche/']")
            if not a:
                continue
            pr = li.select_one(".price")
            rt = li.select_one(".ratingClient a")
            res.append({"title": clean(a.get_text(" ")), "url": "https://www.ldlc.com" + a["href"],
                        "price": clean(pr.get_text()) if pr else None,
                        "rating": clean(rt.get_text(" ")) if rt else None})
    elif site == "cdiscount":
        sp = soup(br.get(f"https://www.cdiscount.com/search/10/{quote_plus(q)}.html", scroll=True))
        seen = set()
        for a in sp.select('a[href*="/f-"]'):
            href = a["href"].split("#")[0].split("?")[0]
            if href.startswith("//"):
                href = "https:" + href
            t = clean(a.get_text(" "))
            if href in seen or not re.search(r"/f-\d+-", href) or len(t) < 15:
                continue
            seen.add(href)
            pm = re.findall(r"\d[\d ]*,\d{2} €", t)
            rm = re.search(r"([\d,]+ / 5)\s+(\d+ avis)", t)
            title = re.sub(r"^(Meilleur prix \? |Sponsorisé.*?\? )", "", t)
            res.append({"title": title[:110], "url": href, "price": pm[-1] if pm else None,
                        "rating": " ".join(rm.groups()) if rm else None})
    elif site == "topachat":
        br.get("https://www.topachat.com/", wait=1500)
        pg = br.page
        box = pg.locator("form[role=search] input").first
        box.fill(q)
        box.press("Enter")
        pg.wait_for_timeout(4000)
        sp = soup(pg.content())
        seen = set()
        for a in sp.select('a[href*="detail2_cat_est_"]'):
            href = a["href"].split("#")[0]
            href = "https://www.topachat.com" + href if href.startswith("/") else href
            t = clean(a.get_text(" "))
            if href in seen or len(t) < 8:
                continue
            seen.add(href)
            pm = re.search(r"\d[\d ]*[.,]\d{2} €", t)
            res.append({"title": t[:110], "url": href, "price": pm.group(0) if pm else None, "rating": None})
    elif site == "amazon":
        raise NotProduct("La recherche Amazon /s?k= est inexploitable (consentement, anti-bot). "
                         "Utiliser brave-search avec site:amazon.fr/dp, puis shop.py <url /dp/>.")
    return res[:limit]
