import os
import sys

from rest_framework.test import APIClient

from authentik.brands.models import Brand
from authentik.core.models import Group, User
from authentik.stages.email.models import EmailStage

email = os.environ["INVITE_EMAIL"].strip().lower()
name = os.environ.get("INVITE_NAME", "").strip() or email.split("@")[0]
group_names = os.environ.get("INVITE_GROUPS", "").split()
timezone = os.environ.get("INVITE_TIMEZONE", "").strip()
locale = os.environ.get("INVITE_LOCALE", "").strip()
workspace = os.environ.get("INVITE_WORKSPACE", "").strip()
context = os.environ.get("INVITE_CONTEXT", "").strip() or "mossyleaf"
secure = os.environ.get("INVITE_SECURE", "") == "1"
duration = os.environ.get("INVITE_DURATION", "days=7")

# The link and the email follow the context's brand: its domain, look and sender.
brand = Brand.objects.filter(attributes__context=context).first()
if brand is None:
    sys.exit(f"Unknown context: {context}")

groups = []
for group_name in group_names:
    group = Group.objects.filter(name=group_name).first()
    if group is None:
        sys.exit(f"Unknown group: {group_name}")
    groups.append(group)

user = User.objects.filter(email__iexact=email).first()
if user is None:
    user = User(username=email, email=email, name=name, is_active=True)
    user.set_unusable_password()
    user.save()
    print(f"Created {email}")
else:
    print(f"{email} already exists")

if timezone and not user.attributes.get("timezone"):
    user.attributes["timezone"] = timezone
if locale and not user.attributes.get("settings", {}).get("locale"):
    user.attributes.setdefault("settings", {})["locale"] = locale
if workspace:
    user.attributes["mossytrunk_workspace"] = workspace
user.save()

for group in groups:
    user.groups.add(group)
print("Groups: " + (", ".join(sorted(group.name for group in user.groups.all())) or "none"))
if user.attributes.get("mossytrunk_workspace"):
    print(f"MossyTrunk workspace: {user.attributes['mossytrunk_workspace']}")

admin = User.objects.filter(is_active=True, groups__is_superuser=True).first()
if admin is None:
    sys.exit("No active superuser to send the invitation as")
stage = EmailStage.objects.get(name=f"{context}-invitation-email")
client = APIClient()
client.force_authenticate(admin)
response = client.post(
    f"/api/v3/core/users/{user.pk}/recovery_email/",
    {"email_stage": str(stage.pk), "token_duration": duration},
    format="json",
    HTTP_HOST=brand.domain,
    HTTP_ACCEPT_LANGUAGE=user.attributes.get("settings", {}).get("locale") or "en",
    secure=secure,
)
if response.status_code != 204:
    sys.exit(f"Sending failed ({response.status_code}): {response.content.decode()}")
print(f"{brand.branding_title} invitation sent to {email} (valid {duration})")
