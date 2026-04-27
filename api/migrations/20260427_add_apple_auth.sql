ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS apple_sub text;

CREATE UNIQUE INDEX IF NOT EXISTS users_apple_sub_uniq
    ON public.users USING btree (apple_sub)
    WHERE apple_sub IS NOT NULL;
