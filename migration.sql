-- VARASTO QR - PÄÄTUOTTEET, ALATUOTTEET JA YKSIKÖT
-- Aja tämä kerran nykyisessä Supabase-projektissa SQL Editorissa.

-- 1) Tuoterakenne: päätuote / alatuote
alter table public.products
  add column if not exists parent_id uuid references public.products(id) on delete set null;

create index if not exists idx_products_parent on public.products(parent_id);

-- 2) Yksikkö ja desimaalimäärät
alter table public.products
  add column if not exists unit text not null default 'kpl';

alter table public.products
  alter column quantity type numeric(14,3) using quantity::numeric,
  alter column min_quantity type numeric(14,3) using min_quantity::numeric;

-- Rajoitetaan yksiköt kolmeen vaihtoehtoon.
alter table public.products drop constraint if exists products_unit_check;
alter table public.products
  add constraint products_unit_check check (unit in ('kpl','kg','l'));

-- 3) Historiaan yksikkö ja desimaalimäärät
alter table public.stock_movements
  add column if not exists unit text not null default 'kpl';

alter table public.stock_movements
  alter column delta type numeric(14,3) using delta::numeric,
  alter column balance_after type numeric(14,3) using balance_after::numeric;

alter table public.stock_movements drop constraint if exists stock_movements_unit_check;
alter table public.stock_movements
  add constraint stock_movements_unit_check check (unit in ('kpl','kg','l'));

-- 4) Korvataan vanha integer-versio atomisesta varastomuutoksesta desimaalit sallivalla versiolla.
drop function if exists public.change_stock(uuid, integer);
drop function if exists public.change_stock(uuid, numeric);

create function public.change_stock(p_product_id uuid, p_delta numeric)
returns public.products
language plpgsql
security invoker
as $$
declare
  p public.products;
  new_qty numeric(14,3);
begin
  select * into p from public.products where id = p_product_id for update;
  if not found then raise exception 'Tuotetta ei löytynyt'; end if;

  if p.unit = 'kpl' and p_delta <> trunc(p_delta) then
    raise exception 'Kappalemäärän pitää olla kokonaisluku';
  end if;

  new_qty := p.quantity + p_delta;
  if new_qty < 0 then raise exception 'Varastossa ei ole tarpeeksi tuotetta'; end if;

  update public.products
  set quantity = new_qty, updated_at = now()
  where id = p_product_id
  returning * into p;

  insert into public.stock_movements(product_id, product_name, delta, balance_after, unit, user_id)
  values(p.id, p.name, p_delta, p.quantity, p.unit, auth.uid());

  return p;
end;
$$;

grant execute on function public.change_stock(uuid, numeric) to authenticated;

-- Varmistetaan, että kirjautuneet käyttäjät saavat kirjoittaa tapahtumahistorian.
drop policy if exists "authenticated insert movements" on public.stock_movements;
create policy "authenticated insert movements"
on public.stock_movements
for insert to authenticated
with check (true);

grant insert on table public.stock_movements to authenticated;

-- Varmistetaan olemassa olevat lukuoikeudet.
grant select on table public.products, public.stock_movements to authenticated;
