-- ============================================================
-- CARDONA — Schéma de base de données (Supabase / PostgreSQL)
-- ============================================================
-- À exécuter dans : Supabase → SQL Editor → New query → Run
-- ============================================================


-- ============================================================
-- 1. PROFILS UTILISATEURS
-- Étend la table auth.users gérée automatiquement par Supabase
-- ============================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text,
  avatar_url text,
  role text not null default 'expediteur' check (role in ('expediteur', 'transporteur', 'both')),
  rating numeric(2,1) default 0,
  nb_trajets integer default 0,
  verification_status text not null default 'non_soumis'
    check (verification_status in ('non_soumis', 'en_attente', 'verifie', 'refuse', 'incomplet')),
  verification_docs jsonb default '[]'::jsonb, -- liste de fichiers (CNI, permis, etc.)
  is_suspended boolean default false,
  created_at timestamptz default now()
);

-- Crée automatiquement un profil quand quelqu'un s'inscrit
create function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', 'Nouvel utilisateur'));
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ============================================================
-- 2. TRAJETS (publiés par les transporteurs)
-- ============================================================
create table public.trajets (
  id uuid primary key default gen_random_uuid(),
  transporteur_id uuid not null references public.profiles(id) on delete cascade,
  mode_transport text not null check (mode_transport in ('avion', 'camion_fourgon', 'voiture', 'train_bus', 'autre')),
  lieu_ramassage text not null,
  lieu_distribution text not null,
  date_ramassage timestamptz not null,
  date_distribution timestamptz not null,
  prix numeric(10,2) not null,
  devise text default 'EUR',
  statut text not null default 'publie' check (statut in ('publie', 'complet', 'termine', 'annule')),
  created_at timestamptz default now()
);

create index idx_trajets_transporteur on public.trajets(transporteur_id);
create index idx_trajets_statut on public.trajets(statut);


-- ============================================================
-- 3. RÉSERVATIONS (un colis sur un trajet = NCC)
-- ============================================================
create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  ncc text unique not null default ('NCC-' || floor(random() * 9000 + 1000)::text),
  trajet_id uuid not null references public.trajets(id) on delete cascade,
  expediteur_id uuid not null references public.profiles(id) on delete cascade,
  poids_kg numeric(6,2),
  categorie text check (categorie in ('marchandise', 'document', 'fragile', 'electronique', 'autre')),
  description text,
  prix_transporteur numeric(10,2) not null,
  frais_service numeric(10,2) not null default 2.00,
  prix_total numeric(10,2) generated always as (prix_transporteur + frais_service) stored,
  statut text not null default 'en_attente'
    check (statut in ('en_attente', 'confirme', 'refuse', 'en_cours', 'livre', 'annule')),
  created_at timestamptz default now()
);

create index idx_reservations_trajet on public.reservations(trajet_id);
create index idx_reservations_expediteur on public.reservations(expediteur_id);


-- ============================================================
-- 4. MESSAGES (messagerie liée à une réservation/trajet)
-- ============================================================
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  read_at timestamptz,
  created_at timestamptz default now()
);

create index idx_messages_reservation on public.messages(reservation_id);


-- ============================================================
-- 5. PAIEMENTS
-- ============================================================
create table public.paiements (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  montant numeric(10,2) not null,
  methode text check (methode in ('carte', 'paypal', 'autre')),
  statut text not null default 'en_attente' check (statut in ('en_attente', 'paye', 'echoue', 'rembourse')),
  stripe_payment_id text,
  created_at timestamptz default now()
);


-- ============================================================
-- 6. NOTIFICATIONS
-- ============================================================
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  content text not null,
  is_read boolean default false,
  created_at timestamptz default now()
);

create index idx_notifications_user on public.notifications(user_id, is_read);


-- ============================================================
-- 7. SÉCURITÉ — Row Level Security (RLS)
-- Empêche un utilisateur de voir/modifier les données des autres
-- ============================================================
alter table public.profiles enable row level security;
alter table public.trajets enable row level security;
alter table public.reservations enable row level security;
alter table public.messages enable row level security;
alter table public.paiements enable row level security;
alter table public.notifications enable row level security;

-- Profils : tout le monde peut voir les profils publics, mais on ne modifie que le sien
create policy "Profils visibles par tous" on public.profiles for select using (true);
create policy "Modifier son propre profil" on public.profiles for update using (auth.uid() = id);

-- Trajets : visibles par tous, modifiables uniquement par leur transporteur
create policy "Trajets visibles par tous" on public.trajets for select using (true);
create policy "Créer son trajet" on public.trajets for insert with check (auth.uid() = transporteur_id);
create policy "Modifier son trajet" on public.trajets for update using (auth.uid() = transporteur_id);

-- Réservations : visibles par l'expéditeur et le transporteur concernés
create policy "Voir ses réservations" on public.reservations for select
  using (
    auth.uid() = expediteur_id
    or auth.uid() in (select transporteur_id from public.trajets where id = trajet_id)
  );
create policy "Créer une réservation" on public.reservations for insert with check (auth.uid() = expediteur_id);

-- Messages : visibles par les deux parties de la réservation concernée
create policy "Voir ses messages" on public.messages for select
  using (
    auth.uid() in (
      select expediteur_id from public.reservations where id = reservation_id
      union
      select t.transporteur_id from public.trajets t
      join public.reservations r on r.trajet_id = t.id
      where r.id = reservation_id
    )
  );
create policy "Envoyer un message" on public.messages for insert with check (auth.uid() = sender_id);

-- Notifications : chacun voit uniquement les siennes
create policy "Voir ses notifications" on public.notifications for select using (auth.uid() = user_id);


-- ============================================================
-- 8. DONNÉES DE TEST (optionnel — à supprimer en production)
-- ============================================================
-- Décommentez après avoir créé des comptes test via l'auth Supabase
-- insert into public.trajets (transporteur_id, mode_transport, lieu_ramassage, lieu_distribution, date_ramassage, date_distribution, prix)
-- values ('UUID_DU_TRANSPORTEUR', 'avion', 'Aéroport de Marseille', 'Aéroport de Tunis', '2025-05-05 10:00', '2025-05-05 13:00', 15.00);

-- ============================================================
-- FIN DU SCRIPT
-- ============================================================
