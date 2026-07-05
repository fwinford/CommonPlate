import 'dotenv/config';
import mongoose from 'mongoose';
import { Subscriber } from '../models/db.ts';

(async ()=>{
  try {
    await mongoose.connect(process.env.MONGO_URI!);
    const t='6916b4fec6bd2543cdee9b33';
    const sub = await Subscriber.findOne({ confirmToken: t }).exec();
    console.log('found', !!sub);
    if(!sub){ console.log('no sub'); process.exit(0);}
  sub.status='confirmed';
  sub.confirmToken = undefined as any;
  if (!sub.unsubToken) sub.unsubToken = new mongoose.Types.ObjectId().toString() as any;
  await sub.save();
    console.log('saved');
    await mongoose.disconnect();
  } catch(e){ console.error(e); process.exit(1); }
})();
