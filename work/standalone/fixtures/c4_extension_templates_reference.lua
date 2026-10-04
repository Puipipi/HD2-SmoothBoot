-- Rounds/Reload template-loop reference excerpts adapted from HD2 C4 Quick Actions, MIT license.
-- Copyright (c) 2026 HD2 C4 Quick Actions contributors
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.


function rounds_extend(e,row)
local read,ptr,u32=e.read,e.ptr,e.u32
local config
local templates=ptr(e.owner+D.rounds_templates,true)


                local start=0
                for b=8,1,-1 do start=(start*256+e.weapon:byte(b))%D.rounds_capacity end
                for probe=0,D.rounds_capacity-1 do
                    local entry=read(templates+((start+probe)%D.rounds_capacity)*16,16,true)
                    local hash=e.resource(entry)
                    if hash=='0000000000000000' then break end
                    if hash==row.current_weapon_resource then
                        local ti=u32(entry,8)
                        assert(ti<D.rounds_capacity,'rounds_template_index_limit')
                        config=read(templates+D.rounds_capacity*16+ti*D.rounds_stride,D.rounds_stride,true)
                        break
                    end
                end

assert(config,"rounds_config_missing")
return {same=e.checked,config=config}
end

function reload_extend(e,row)
local read,ptr,u32=e.read,e.ptr,e.u32
local config
local templates=ptr(e.owner+D.reload_templates,true);local start=0
        for b=8,1,-1 do start=(start*256+e.weapon:byte(b))%D.reload_capacity end
        for probe=0,D.reload_capacity-1 do
            local entry=read(templates+((start+probe)%D.reload_capacity)*16,16,true)
            if e.resource(entry)=='0000000000000000' then break end
            if e.resource(entry)==row.current_weapon_resource then
                local ti=u32(entry,8);assert(ti<D.reload_capacity,'reload_template_index')
                config=read(templates+D.reload_capacity*16+ti*D.reload_stride,D.reload_stride,true);break
            end
        end

assert(config,"reload_config_missing")
return {same=e.checked,config=config}
end
