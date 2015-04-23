def upgrade ta, td, a, d
  a['windows'] = ta['windows']
  return a, d
end

def downgrade ta, td, a, d
  a.delete('windows')
  return a, d
end
