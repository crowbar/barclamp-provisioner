def upgrade ta, td, a, d
  a['serial_tty'] = ta['serial_tty']
  return a, d
end

def downgrade ta, td, a, d
  a.delete('serial_tty')
  return a, d
end
