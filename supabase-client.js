import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Remplace ces deux valeurs par celles de ton projet Supabase
// (Project Settings > API dans le dashboard Supabase)
const SUPABASE_URL = 'https://wjpfbmdexfobkktaolhy.supabase.co/rest/v1/';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndqcGZibWRleGZvYmtrdGFvbGh5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg4ODQwMzAsImV4cCI6MjEwNDQ2MDAzMH0.LhxH82NFtRiaquuI2Le_4Y9HC9sVLF8M0_L4iPB1-Bw';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
