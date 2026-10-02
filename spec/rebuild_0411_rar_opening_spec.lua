local fixture=dofile('spec/rebuild_0411_7z_opening_spec.lua')
for _,format in ipairs({'rar','cbr'}) do
    fixture.run(25,false,nil,nil,nil,format)
    fixture.run(25,true,nil,nil,nil,format)
    fixture.run(2,false,nil,nil,nil,format)
    fixture.run(25,false,nil,true,nil,format)
    fixture.run(25,false,nil,nil,'corrupt_third',format)
    fixture.run(25,false,'archive_truncated',nil,nil,format)
    fixture.cached_open('valid',nil,format)
    for _,mode in ipairs({'legacy','unversioned','stale'}) do
        fixture.cached_open(mode,2,format)
    end
    fixture.cached_open('mixed',nil,format)
    fixture.cached_open('legacy-tail',nil,format)
    for _,mode in ipairs({'legacy-foreign','foreign-owner','record-race','delete-fails','new-part-corrupt'}) do
        fixture.cached_open(mode,2,format)
    end
end
print('rebuild_0411_rar_opening_spec: staged opening, background, cancellation and errors passed')
