variable "supabase_service_key" {
  type        = string
  sensitive   = true
  description = "Supabase service_role key (do not commit!)"
}

variable "supabase_url" {
  type        = string
  description = "Your Supabase project URL (e.g. https://abcd1234.supabase.co)"
}