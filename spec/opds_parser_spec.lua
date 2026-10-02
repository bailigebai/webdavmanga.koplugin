local Parser = require("webdavmanga.opds_parser")

local xml = [[
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>我的漫画 &amp; 书架</title>
  <link rel="next" href="page=2" />
  <link rel="search" href="search.xml?q={searchTerms}" type="application/opensearchdescription+xml" />
  <entry>
    <id>series-1</id>
    <title>第一系列</title>
    <link rel="subsection" href="series/1" />
    <link rel="http://opds-spec.org/image" href="covers/1.jpg" type="image/jpeg" />
  </entry>
  <entry>
    <id>page-1</id>
    <title>第一页</title>
    <content type="text">图片页</content>
    <link rel="http://opds-spec.org/image" href="pages/1.jpg" type="image/jpeg" />
  </entry>
</feed>
]]

local catalog = assert(Parser.parse(xml, "https://example.test/opds/catalog"))
assert(catalog.title == "我的漫画 & 书架")
assert(catalog.is_atom_feed == true, "Atom root marker must survive parsing")
assert(catalog.next_url == "https://example.test/opds/page=2")
assert(catalog.search_url == "https://example.test/opds/search.xml?q={searchTerms}")
assert(#catalog.entries == 2)
assert(catalog.entries[1].id == "series-1")
assert(catalog.entries[1].kind == "series")
assert(catalog.entries[1].href == "https://example.test/opds/series/1")
assert(catalog.entries[1].image_url == "https://example.test/opds/covers/1.jpg")
assert(catalog.entries[2].kind == "page")
assert(catalog.entries[2].image_url == "https://example.test/opds/pages/1.jpg")

local other = assert(Parser.parse(
    '<collection><entry><title>伪目录</title></entry></collection>',
    "https://example.test/other"))
assert(other.is_atom_feed == false and #other.entries == 1,
    "nested entry tags must not make a non-Atom root look like a feed")

local atom_ns = 'http://www.w3.org/2005/Atom'
local bom_feed = assert(Parser.parse('\239\187\191<feed xmlns="' .. atom_ns
    .. '"><entry><title>合法卷</title></entry></feed>', "https://example.test/opds"))
assert(bom_feed.is_atom_feed == true,
    "UTF-8 BOM must not hide a valid Atom feed root")
local wrong_ns = assert(Parser.parse('<feed xmlns="urn:not-atom">'
    .. '<entry><title>伪卷</title></entry></feed>', "https://example.test/opds"))
assert(wrong_ns.is_atom_feed == false,
    "a feed tag in the wrong namespace must not pass Atom validation")
local double_root = assert(Parser.parse('<feed xmlns="' .. atom_ns
    .. '"><entry><title>甲</title></entry></feed><feed xmlns="' .. atom_ns
    .. '"><entry><title>乙</title></entry></feed>', "https://example.test/opds"))
assert(double_root.is_atom_feed == false,
    "two top-level feed elements must not pass the single-root contract")
local self_closing_double_root = assert(Parser.parse('<feed xmlns="' .. atom_ns
    .. '"/><feed xmlns="' .. atom_ns
    .. '"><entry><title>伪卷</title></entry></feed>', "https://example.test/opds"))
assert(self_closing_double_root.is_atom_feed == false,
    "a self-closing feed followed by another feed must not pass single-root validation")
local empty_feed = assert(Parser.parse('<feed xmlns="' .. atom_ns .. '"/>',
    "https://example.test/opds"))
assert(empty_feed.is_atom_feed == true,
    "a single self-closing Atom feed is still one valid root")
local prefixed = assert(Parser.parse('<atom:feed xmlns:atom="' .. atom_ns
    .. '"><atom:entry><atom:title>卷</atom:title></atom:entry></atom:feed>',
    "https://example.test/opds"))
assert(prefixed.is_atom_feed == true,
    "a prefix bound to the Atom namespace must count as an Atom feed")

local pse = assert(Parser.parse([[<a:feed xmlns:a="http://www.w3.org/2005/Atom"
    xmlns:pse="http://vaemendis.net/opds-pse/ns">
  <a:id>urn:suwayomi:manga:9</a:id><a:title>Series</a:title>
  <a:author><a:name>Suwayomi</a:name></a:author>
  <a:entry><a:id>urn:suwayomi:chapter:abc:metadata</a:id><a:title>Chapter</a:title>
    <a:link rel="http://vaemendis.net/opds-pse/stream"
      href="https://srv/chapter/abc/page/{pageNumber}" pse:count="27"
      pse:lastRead="2" type="image/jpeg" />
    <a:link rel="next" href="not-the-feed-next" />
  </a:entry>
</a:feed>]], "https://srv/opds/metadata"))
assert(pse.entries[1].kind == "volume", "PSE is a stream, never a page")
assert(pse.entries[1].image_url == nil, "PSE template cannot become a cover")
assert(pse.entries[1].stream.template == "https://srv/chapter/abc/page/{pageNumber}")
assert(pse.entries[1].stream.count == 27 and pse.entries[1].stream.last_read == 2)
assert(pse.entries[1].links[1]["pse:count"] == "27", "attribute prefixes must survive")
assert(pse.author == "Suwayomi" and pse.id == "urn:suwayomi:manga:9")
assert(pse.next_url == nil, "entry next must not replace feed pagination")
local suffix = assert(Parser.parse([[<feed xmlns="http://www.w3.org/2005/Atom"><entry>
 <link rel="http://opds-spec.org/image" href="cover.jpg" type="image/jpeg"/>
 <link rel="http://vaemendis.net/opds-pse/stream" href="p/{pageNumber}"
   pse_count="27" pse_lastRead="2.5" type="image/jpeg"/>
</entry></feed>]], "https://srv/opds/chapter"))
assert(suffix.entries[1].stream.count == 27 and suffix.entries[1].stream.last_read == nil)
assert(suffix.entries[1].kind == "volume", "a stream with a cover stays readable as a volume")
assert(suffix.entries[1].image_url == "https://srv/opds/cover.jpg")
print("opds_parser_spec: passed")
