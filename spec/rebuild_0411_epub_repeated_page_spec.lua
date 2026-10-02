local fixture = dofile('spec/rebuild_0411_epub_opening_spec.lua')
local Pages = require('webdavmanga.archive_pages')
local Index = require('webdavmanga.book_index')
local checks=0
local function expect(value,message) checks=checks+1; assert(value,message) end
for _,kind in ipairs({'direct','xhtml','svg'}) do
    local bytes=fixture.book(kind,6,false,true)
    local source={size=#bytes,read_at=function(offset,count) return bytes:sub(offset+1,offset+count) end}
    local reader=Pages:new()
    local options={page_limit=3,source_version='v1',generation='r1'}
    local result=assert(reader:inspect_remote(source,'epub','/book.epub',options))
    local a,b=result.index:get(1),result.index:get(2)
    expect(a.path~=b.path,kind..' repeated image must have independent logical page cache paths')
    expect(a~=b and a.archive_local_offset==b.archive_local_offset,
        'logical pages retain shared image bytes without shared mutable descriptors')
    expect(result.total_pages==6 and result.index:count()==3,'spine repeats remain real reading pages')
    expect(Index.from_table(result.index:to_table())~=nil,'logical page survives cache/worker serialization')
    local resumed=assert(reader:inspect_remote(source,'epub','/book.epub',{
        continuation=result.continuation,start_page=4,source_version='v1',generation='r1'}))
    local seen={}
    for pos=1,6 do
        local page=resumed.index:get(pos)
        expect(page and not seen[page.path],'resume preserves unique logical page '..pos)
        seen[page.path]=true
    end
    local encoded=resumed.index:to_table()
    encoded.items[2].archive_spine_position=0
    expect(not Index.from_table(encoded),'invalid spine position cannot enter persisted cache')
end
print(('rebuild_0411_epub_repeated_page_spec: %d checks'):format(checks))
