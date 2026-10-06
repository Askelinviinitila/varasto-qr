-- VARASTO QR CLOUD / SUPABASE
-- Aja tämä Supabasen SQL Editorissa.

create extension if not exists pgcrypto;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text not null unique,
  qr_code text unique,
  quantity integer not null default 0 check (quantity >= 0),
  min_quantity integer not null default 0 check (min_quantity >= 0),
  location text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  product_name text not null,
  delta integer not null,
  balance_after integer not null,
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_products_qr on public.products(qr_code);
create index if not exists idx_movements_created on public.stock_movements(created_at desc);

alter table public.products enable row level security;
alter table public.stock_movements enable row level security;

drop policy if exists "authenticated read products" on public.products;
create policy "authenticated read products" on public.products for select to authenticated using (true);

drop policy if exists "authenticated insert products" on public.products;
create policy "authenticated insert products" on public.products for insert to authenticated with check (true);

drop policy if exists "authenticated update products" on public.products;
create policy "authenticated update products" on public.products for update to authenticated using (true) with check (true);

drop policy if exists "authenticated delete products" on public.products;
create policy "authenticated delete products" on public.products for delete to authenticated using (true);

drop policy if exists "authenticated read movements" on public.stock_movements;
create policy "authenticated read movements" on public.stock_movements for select to authenticated using (true);

-- Atomicinen saldomuutos: estää tilanteen, jossa kaksi käyttäjää muuttaa samaa saldoa samanaikaisesti.
create or replace function public.change_stock(p_product_id uuid, p_delta integer)
returns public.products
language plpgsql
security invoker
as $$
declare
  p public.products;
  new_qty integer;
begin
  select * into p from public.products where id = p_product_id for update;
  if not found then raise exception 'Tuotetta ei löytynyt'; end if;

  new_qty := p.quantity + p_delta;
  if new_qty < 0 then raise exception 'Varastossa ei ole tarpeeksi tuotetta'; end if;

  update public.products
  set quantity = new_qty, updated_at = now()
  where id = p_product_id
  returning * into p;

  insert into public.stock_movements(product_id, product_name, delta, balance_after, user_id)
  values(p.id, p.name, p_delta, p.quantity, auth.uid());

  return p;
end;
$$;

grant execute on function public.change_stock(uuid, integer) to authenticated;

-- Reaaliaikaiset päivitykset (valinnainen, mutta hyödyllinen usean laitteen käytössä)
alter publication supabase_realtime add table public.products;
alter publication supabase_realtime add table public.stock_movements;
