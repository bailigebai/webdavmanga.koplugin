local Parser=require('webdavmanga.opds_parser')
local Ui=require('webdavmanga.ui_opds')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function parsed(entries,author,url)
    return assert(Parser.parse('<feed xmlns="http://www.w3.org/2005/Atom" '
        ..'xmlns:pse="http://vaemendis.net/opds-pse/ns"><title>Catalog</title>'
        ..'<author><name>'..author..'</name></author>'..entries..'</feed>',url))
end
local function run(kind,author,chapter_id,stream)
    local source={id='s1',server_kind=kind,url='https://srv/opds/v1.2/catalog'}
    local root='https://srv'..(author=='Suwayomi' and '/api/v1/opds/manga/9' or '/opds/v1.2/series/S')
    local detail='https://srv/detail/book'
    local first=parsed('<entry><id>'..chapter_id..'</id><title>Chapter</title>'
        ..'<link rel="http://opds-spec.org/acquisition" '
        ..'type="application/atom+xml;profile=opds-catalog;type=entry" href="'..detail..'"/></entry>',author,root)
    local ready=parsed('<entry><id>'..chapter_id..(author=='Suwayomi' and ':metadata' or '')
        ..'</id><title>Chapter</title><link rel="http://vaemendis.net/opds-pse/stream" '
        ..'type="image/jpeg" href="'..stream..'" pse:count="20"/></entry>',author,detail)
    local menus,infos,fetches,opened={},{},{},nil
    local app=Ui:new{catalog={fetch=function(_,id,url)
            expect(id=='s1','selected source retained')
            fetches[#fetches+1]=url
            return url==root and first or url==detail and ready or nil
        end},reader={},pointer={},ui={show_menu=function(_,model) menus[#menus+1]=model;return true end,
            show_info=function(_,text) infos[#infos+1]=text;return true end},
        async={run=function(work,done) local ok,result=pcall(work);done(ok,result);return {} end}}
    app.request_open=function(_,descriptor) opened=descriptor;return true end
    expect(app:open_url(source,root,nil,nil,root,
        {series_id='S',series_name='Series',series_feed_url=root}),'chapter catalog opens')
    expect(first.entries[1].kind=='volume' and not first.entries[1].stream,
        'full-entry link is not yet a ready streaming chapter')
    menus[1].items[1].callback()
    expect(fetches[2]==detail and #infos==0,'pointer must not turn detail navigation into chapter parse failure')
    if author~='Suwayomi' then
        expect(not opened,'details feed is shown before choosing its real PSE entry')
        expect(menus[2].items[1].callback(),'ready chapter selection succeeds')
    end
    expect(opened and opened.page_count==20,'ready PSE chapter resolves with pointer enabled')
    expect(opened.chapter_id==chapter_id,'stable chapter identity retained')
    expect(opened.series_id=='S' and opened.series_name=='Series',
        'detail navigation retains proven parent series context')
end
run('komga','Komga','B','https://srv/opds/v1.2/books/B/pages/{pageNumber}')
run('auto','Komga','B','https://srv/opds/v1.2/books/B/pages/{pageNumber}')
run('suwayomi','Suwayomi','urn:chapter:1','https://srv/chapter/1/page/{pageNumber}')
run('auto','Suwayomi','urn:chapter:1','https://srv/chapter/1/page/{pageNumber}')
for _,reason in ipairs({'invalid_page_count','unsupported_server','missing_chapter_id',
    'https://private/credential-value',false}) do
    local message,lines=nil,{}
    local app=Ui:new{catalog={},reader={},ui={show_info=function(_,text) message=text end},
        logger={warn=function(...) lines[#lines+1]=table.concat({...},' ') end},
        driver={resolve=function() return nil,reason end}}
    app.current={feed={},feed_url='https://srv/catalog'}
    app:_open_entry({id='s1',server_kind='komga'},
        {stream={template='https://srv/private/credential-value',count=20}})
    expect(message and #lines==1,'resolution rejection has a message and fixed diagnostic')
    expect(not (message..lines[1]):find('credential-value',1,true),
        'UI and log never echo untrusted reason or request URL')
    if reason=='invalid_page_count' then expect(message:find('页数',1,true),'invalid count is explained')
    elseif reason=='unsupported_server' then expect(message:find('服务类型',1,true),'service detection is explained')
    elseif reason=='missing_chapter_id' then expect(message:find('章节编号',1,true),'missing identity is explained')
    else expect(lines[1]:find('reason=unknown',1,true),'unknown errors use a fixed category') end
end
print(('rebuild_0411_opds_entry_routing_spec: %d checks'):format(checks))
