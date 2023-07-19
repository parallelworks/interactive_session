
version=$(cat utils/input_form_resource_wrapper.py | grep VERSION | cut -d':' -f2)
if [ -z "$version" ] || [ "$version" -lt 1 ]; then
  echo "NO"
else
  echo "YES"
fi