import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const bank=JSON.parse(await fs.readFile(path.join(root,'src/cases.json'),'utf8'));
export const revision='2026-11-24.1';
const quote=value=>"'"+String(value).replaceAll("'","''")+"'";
const rows=bank.flatMap(c=>c.items.map((q,i)=>'('+[revision,c.id+'-'+i,c.id,
  ['M2-01','M2-02'].includes(c.id)?'2-casemix':String(c.module)==='2'?'2-coding':String(c.module),
  q.prompt,JSON.stringify(q.options),q.correct,q.feedback].map(quote).join(',')+')'));
// Existing tabs use the legacy RPC and legacy bank. New clients request the
// explicit revision so an open browser never mixes new keys with old questions.
const bankNames=(await fs.readdir(path.join(root,'supabase/banks'))).filter(n=>n.endsWith('.sql')).sort();
const legacy=(await Promise.all(bankNames.map(n=>fs.readFile(path.join(root,'supabase/banks',n),'utf8')))).join('\n');
const current=`begin;\ninsert into idrg_private.bank_versions(revision,active) values(${quote(revision)},false) on conflict(revision) do nothing;\ninsert into idrg_private.questions(revision,item_id,case_id,packet_id,prompt,options,correct,feedback) values\n${rows.join(',\n')}\non conflict(revision,item_id) do nothing;\ncommit;\n`;
const sql=legacy+'\n'+current;
await fs.mkdir(path.join(root,'supabase'),{recursive:true});
await fs.writeFile(path.join(root,'supabase/seed.sql'),sql);
console.log('Seed ready: 112 questions; existing revision keys stay immutable.');

const names=(await fs.readdir(path.join(root,'supabase/migrations'))).filter(n=>n.endsWith('.sql')).sort();
const migrations=await Promise.all(names.map(n=>fs.readFile(path.join(root,'supabase/migrations',n),'utf8')));
await fs.writeFile(path.join(root,'supabase/setup.sql'),migrations.join('\n')+'\n'+sql);

const neonSchema=await fs.readFile(path.join(root,'neon/schema.sql'),'utf8');
await fs.mkdir(path.join(root,'neon'),{recursive:true});
await fs.writeFile(path.join(root,'neon/setup.sql'),neonSchema+'\n'+sql);
