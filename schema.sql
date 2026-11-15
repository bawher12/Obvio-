-- Obvio! · Etapa 1 · Pegar completo en Supabase > SQL Editor > Run
create table profiles(
  id uuid primary key references auth.users on delete cascade,
  nombre text not null,
  rol text not null check (rol in ('propietario','inquilino')),
  plan text not null default 'gratis' check (plan in ('gratis','basico','plus','empresarial')),
  created_at timestamptz default now());

create table inmuebles(
  id uuid primary key default gen_random_uuid(),
  propietario_id uuid not null references profiles(id) on delete cascade,
  inquilino_id uuid references profiles(id) on delete set null,
  nombre text not null,
  tipo text not null check (tipo in ('casa','apartamento','bodega','oficina','finca')),
  valor bigint not null check (valor > 0),
  dia_pago int not null check (dia_pago between 1 and 28),
  codigo text not null unique default substr(md5(random()::text || clock_timestamp()::text),1,8),
  created_at timestamptz default now());

create table pagos(
  id uuid primary key default gen_random_uuid(),
  inmueble_id uuid not null references inmuebles(id) on delete cascade,
  periodo date not null,
  valor bigint not null,
  metodo text not null check (metodo in ('bre-b','consignacion')),
  soporte_url text,
  estado text not null default 'por_confirmar' check (estado in ('por_confirmar','confirmado')),
  created_at timestamptz default now(),
  unique (inmueble_id, periodo));

-- Límite de inmuebles según el plan (gratis 2, basico 5, plus 12, empresarial sin límite)
create function limite_plan(p text) returns int language sql immutable as
$$ select case p when 'gratis' then 2 when 'basico' then 5 when 'plus' then 12 else 100000 end $$;

create function validar_limite() returns trigger language plpgsql security definer as $$
begin
  if (select count(*) from inmuebles where propietario_id = new.propietario_id)
     >= limite_plan((select plan from profiles where id = new.propietario_id)) then
    raise exception 'Llegaste al límite de inmuebles de tu plan. Mejora tu plan para agregar más.';
  end if;
  return new;
end $$;
create trigger t_limite before insert on inmuebles for each row execute function validar_limite();

-- El inquilino se une con el código de invitación
create function unirse(p_codigo text) returns uuid language plpgsql security definer as $$
declare v uuid;
begin
  update inmuebles set inquilino_id = auth.uid()
   where codigo = lower(trim(p_codigo)) and inquilino_id is null returning id into v;
  if v is null then raise exception 'Código inválido o ya usado'; end if;
  return v;
end $$;

alter table profiles enable row level security;
alter table inmuebles enable row level security;
alter table pagos enable row level security;

create policy "perfil propio" on profiles for select using (id = auth.uid());
create policy "crear perfil" on profiles for insert with check (id = auth.uid() and plan = 'gratis');
-- El plan solo se cambia desde el panel de Supabase (sin política de update)

create policy "propietario gestiona" on inmuebles for all
  using (propietario_id = auth.uid()) with check (propietario_id = auth.uid());
create policy "inquilino ve el suyo" on inmuebles for select using (inquilino_id = auth.uid());

create policy "propietario ve pagos" on pagos for select
  using (exists (select 1 from inmuebles i where i.id = inmueble_id and i.propietario_id = auth.uid()));
create policy "propietario confirma" on pagos for update
  using (exists (select 1 from inmuebles i where i.id = inmueble_id and i.propietario_id = auth.uid()));
create policy "inquilino ve pagos" on pagos for select
  using (exists (select 1 from inmuebles i where i.id = inmueble_id and i.inquilino_id = auth.uid()));
create policy "inquilino registra pago" on pagos for insert
  with check (estado = 'por_confirmar' and exists (select 1 from inmuebles i where i.id = inmueble_id and i.inquilino_id = auth.uid()));
