### DHCP Database

This special read only Provisioner API is used to manage expose DHCP Entries.

Lists the dhcp entries.

> The testing system is the intended consumer of this API

<table border=1>
  <tr><th> Verb </th><th> URL </th><th> Options </th><th> Returns </th><th> Comments </th></tr>
  <tr><td> GET  </td><td>provisioner/api/v2/dhcp</td><td>N/A</td><td>JSON array of DHCP clients</td><td></td></tr>
  <tr><td> GET  </td><td>provisioner/api/v2/dhcp/[node]</td><td>Information about the requested client only</td><td></td>Provided as convenience for testing<td></tr>
</table>